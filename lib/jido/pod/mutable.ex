defmodule Jido.Pod.Mutable do
  @moduledoc false

  alias Jido.Agent
  alias Jido.AgentServer
  alias Jido.Pod
  alias Jido.Pod.Directive.StartNode
  alias Jido.Pod.Directive.StopNode
  alias Jido.Pod.Mutation
  alias Jido.Pod.Mutation.Plan
  alias Jido.Pod.Mutation.Planner
  alias Jido.Pod.Plugin
  alias Jido.Pod.TopologyState
  alias Jido.Signal

  @pod_state_key Plugin.path()

  @spec mutate(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
          {:ok, %{mutation_id: String.t(), queued: true}} | {:error, term()}
  def mutate(server, ops, opts \\ []) when is_list(opts) do
    signal =
      Signal.new!(
        "pod.mutate",
        %{ops: ops, opts: Map.new(opts)},
        source: "/jido/pod/mutate"
      )

    call_timeout =
      Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, :timer.seconds(30)))

    selector = Keyword.get(opts, :selector, &default_selector/1)

    AgentServer.call(server, signal, selector, timeout: call_timeout)
  end

  @spec mutate_and_wait(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
          {:ok, Pod.mutation_report()} | {:error, term()}
  def mutate_and_wait(server, ops, opts \\ []) when is_list(opts) do
    await_timeout =
      Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, :timer.seconds(30)))

    signal =
      Signal.new!(
        "pod.mutate",
        %{ops: ops, opts: Map.new(opts)},
        source: "/jido/pod/mutate"
      )

    expected_signal_id = signal.id

    # Subscribe BEFORE the cast. The natural child lifecycle signals are the
    # only mutation-progression channel (no synthetic completion signal); the
    # selector reads the slice and matches by mutation.id, returning :skip
    # until MutateProgress flips status to a terminal value.
    selector = terminal_selector(expected_signal_id)

    with {:ok, sub_ref} <-
           AgentServer.subscribe(server, "jido.agent.child.*", selector, once: true) do
      case AgentServer.call(server, signal, &default_selector/1, timeout: await_timeout) do
        {:ok, %{queued: true}} ->
          handle_queued_mutation(server, sub_ref, selector, await_timeout)

        {:error, _reason} = error ->
          _ = AgentServer.unsubscribe(server, sub_ref)
          error
      end
    end
  end

  # The mutation may have already finalized inside that mailbox turn
  # (zero-wave plan), in which case no child lifecycle signal will
  # arrive to fire the subscriber. Re-check the slice once after the
  # call returns to close that gap.
  defp handle_queued_mutation(server, sub_ref, selector, await_timeout) do
    case AgentServer.state(server, fn s -> {:ok, selector.(s)} end) do
      {:ok, {:ok, report}} ->
        _ = AgentServer.unsubscribe(server, sub_ref)
        {:ok, report}

      {:ok, {:error, error}} ->
        _ = AgentServer.unsubscribe(server, sub_ref)
        {:error, error}

      _ ->
        wait_for_terminal(server, sub_ref, await_timeout)
    end
  end

  @spec mutation_effects(Agent.t(), [Mutation.t() | term()], keyword()) ::
          {:ok, map(), [struct()]} | {:error, term()}
  def mutation_effects(%Agent{} = agent, ops, opts \\ []) when is_list(opts) do
    with {:ok, pod_slice} <- TopologyState.fetch_state(agent),
         :ok <- ensure_mutation_idle(pod_slice),
         {:ok, topology} <- TopologyState.fetch_topology(agent),
         {:ok, plan} <- Planner.plan(topology, ops, opts) do
      {phase, awaiting, wave_directives} = first_wave(plan)

      {status, report} =
        if phase == :complete do
          {:completed, finalize_report(plan.report, :completed)}
        else
          {:running, plan.report}
        end

      mutation_state = %{
        id: plan.mutation_id,
        status: status,
        plan: plan,
        phase: phase,
        awaiting: awaiting,
        report: report,
        error: nil
      }

      new_pod_slice = %{
        pod_slice
        | topology: plan.final_topology,
          topology_version: plan.final_topology.version,
          mutation: mutation_state
      }

      {:ok, new_pod_slice, wave_directives}
    end
  end

  defp finalize_report(%Jido.Pod.Mutation.Report{} = report, status) do
    %{report | status: status}
  end

  defp first_wave(%Plan{stop_waves: [first_stop | _]}) do
    {{:stop_wave, 0}, %{kind: :exit, names: MapSet.new(first_stop)},
     Enum.map(first_stop, &StopNode.new!/1)}
  end

  defp first_wave(%Plan{stop_waves: [], start_waves: [first_start | _]} = plan) do
    {{:start_wave, 0}, %{kind: :started, names: MapSet.new(first_start)},
     Enum.map(first_start, &start_directive(&1, plan))}
  end

  defp first_wave(%Plan{stop_waves: [], start_waves: []}) do
    {:complete, nil, []}
  end

  defp start_directive(name, %Plan{start_state_overrides: overrides}) do
    case Map.get(overrides, name) do
      nil -> StartNode.new!(name)
      state when is_map(state) -> StartNode.new!(name, initial_state: state)
    end
  end

  defp ensure_mutation_idle(%{mutation: %{status: status}})
       when status in [:running, :queued] do
    {:error, :mutation_in_progress}
  end

  defp ensure_mutation_idle(_pod_state), do: :ok

  # Default selector for mutate/3: the action's slice return has set the
  # mutation slice (id + status :running) before the selector fires per
  # ADR 0016's hook point. The selector projects the queued ack; on the
  # error branch the framework delivers the action's tagged-tuple
  # `{:error, _}` directly per ADR 0018 §3.
  defp default_selector(%{agent: %{state: agent_state}}) do
    case get_in(agent_state, [@pod_state_key, :mutation]) do
      %{id: id} when not is_nil(id) -> {:ok, %{mutation_id: id, queued: true}}
      _other -> {:error, :mutation_not_set}
    end
  end

  defp terminal_selector(expected_id) do
    fn %{agent: %{state: agent_state}} ->
      case get_in(agent_state, [@pod_state_key, :mutation]) do
        %{id: ^expected_id, status: :completed, report: report} -> {:ok, report}
        %{id: ^expected_id, status: :failed, error: error} -> {:error, error}
        _other -> :skip
      end
    end
  end

  defp wait_for_terminal(server, sub_ref, timeout) do
    receive do
      {:jido_subscription, ^sub_ref, %{result: {:ok, report}}} ->
        {:ok, report}

      {:jido_subscription, ^sub_ref, %{result: {:error, error}}} ->
        {:error, error}
    after
      timeout ->
        _ = AgentServer.unsubscribe(server, sub_ref)
        {:error, :timeout}
    end
  end
end
