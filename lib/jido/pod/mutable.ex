defmodule Jido.Pod.Mutable do
  @moduledoc false

  alias Jido.Agent
  alias Jido.Agent.StateOp
  alias Jido.AgentServer
  alias Jido.Pod
  alias Jido.Pod.Directive.ApplyMutation
  alias Jido.Pod.Mutation
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

    await_timeout =
      Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, :timer.seconds(30)))

    selector = Keyword.get(opts, :selector, &default_selector/1)

    AgentServer.cast_and_await(server, signal, selector, timeout: await_timeout)
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

    # Subscribe FIRST. The lifecycle signal can't fire before the trigger
    # signal's pipeline runs, and `subscribe/4` is a synchronous GenServer.call,
    # so the subscription is registered before the cast hits the mailbox.
    with {:ok, completion_ref} <-
           AgentServer.subscribe(
             server,
             "jido.pod.mutate.completed",
             completion_selector(expected_signal_id),
             once: true
           ),
         {:ok, failure_ref} <-
           AgentServer.subscribe(
             server,
             "jido.pod.mutate.failed",
             failure_selector(expected_signal_id),
             once: true
           ) do
      cast_result =
        AgentServer.cast_and_await(server, signal, &default_selector/1, timeout: await_timeout)

      case cast_result do
        {:ok, %{queued: true}} ->
          wait_for_lifecycle(server, completion_ref, failure_ref, await_timeout)

        {:error, _reason} = error ->
          _ = AgentServer.unsubscribe(server, completion_ref)
          _ = AgentServer.unsubscribe(server, failure_ref)
          error
      end
    end
  end

  @spec mutation_effects(Agent.t(), [Mutation.t() | term()], keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def mutation_effects(%Agent{} = agent, ops, opts \\ []) when is_list(opts) do
    with {:ok, pod_state} <- TopologyState.fetch_state(agent),
         :ok <- ensure_mutation_idle(pod_state),
         {:ok, topology} <- TopologyState.fetch_topology(agent),
         {:ok, plan} <- Planner.plan(topology, ops, opts) do
      mutation_state = %{id: plan.mutation_id, status: :running, report: plan.report, error: nil}

      {:ok,
       [
         StateOp.set_path([@pod_state_key, :topology], plan.final_topology),
         StateOp.set_path([@pod_state_key, :topology_version], plan.final_topology.version),
         StateOp.set_path([@pod_state_key, :mutation], mutation_state),
         ApplyMutation.new!(plan, Keyword.delete(opts, :mutation_id))
       ]}
    end
  end

  defp ensure_mutation_idle(%{mutation: %{status: status}})
       when status in [:running, :queued] do
    {:error, :mutation_in_progress}
  end

  defp ensure_mutation_idle(_pod_state), do: :ok

  # Default selector for mutate/3: the action's StateOp directives have set
  # the mutation slice (id + status: :running) before the selector fires per
  # ADR 0016's hook point. The selector is the "queued" projection — for the
  # error path the framework delivers the action's tagged-tuple {:error, _}
  # directly per ADR 0018 §3.
  defp default_selector(%{agent: %{state: agent_state}}) do
    case get_in(agent_state, [@pod_state_key, :mutation]) do
      %{id: id} when not is_nil(id) -> {:ok, %{mutation_id: id, queued: true}}
      _other -> {:error, :mutation_not_set}
    end
  end

  defp completion_selector(expected_id) do
    fn %{agent: %{state: agent_state}} ->
      case get_in(agent_state, [@pod_state_key, :mutation]) do
        %{id: ^expected_id, status: :completed, report: report} -> {:ok, report}
        _other -> :skip
      end
    end
  end

  defp failure_selector(expected_id) do
    fn %{agent: %{state: agent_state}} ->
      case get_in(agent_state, [@pod_state_key, :mutation]) do
        %{id: ^expected_id, status: :failed, error: error} -> {:error, error}
        _other -> :skip
      end
    end
  end

  defp wait_for_lifecycle(server, completion_ref, failure_ref, timeout) do
    receive do
      {:jido_subscription, ^completion_ref, %{result: {:ok, report}}} ->
        _ = AgentServer.unsubscribe(server, failure_ref)
        {:ok, report}

      {:jido_subscription, ^failure_ref, %{result: {:error, error}}} ->
        _ = AgentServer.unsubscribe(server, completion_ref)
        {:error, error}
    after
      timeout ->
        _ = AgentServer.unsubscribe(server, completion_ref)
        _ = AgentServer.unsubscribe(server, failure_ref)
        {:error, :timeout}
    end
  end
end
