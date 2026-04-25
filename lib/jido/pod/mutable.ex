defmodule Jido.Pod.Mutable do
  @moduledoc false

  alias Jido.Agent
  alias Jido.Agent.StateOp
  alias Jido.AgentServer
  alias Jido.Pod.Directive.ApplyMutation
  alias Jido.Pod.Mutation
  alias Jido.Pod.Mutation.Planner
  alias Jido.Pod.Plugin
  alias Jido.Pod.TopologyState
  alias Jido.Signal

  @pod_state_key Plugin.path()

  @spec mutate(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
          {:ok, Jido.Pod.mutation_report()} | {:error, Jido.Pod.mutation_report() | term()}
  def mutate(server, ops, opts \\ []) when is_list(opts) do
    signal =
      Signal.new!(
        "pod.mutate",
        %{ops: ops, opts: Map.new(opts)},
        source: "/jido/pod/mutate"
      )

    await_timeout =
      Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, :timer.seconds(30)))

    with {:ok, state} <- AgentServer.state(server),
         {:ok, pod_state} <- TopologyState.fetch_state(state),
         :ok <- ensure_mutation_idle(pod_state) do
      run_mutation(server, signal, await_timeout)
    end
  end

  @spec mutation_effects(Agent.t(), [Mutation.t() | term()], keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def mutation_effects(%Agent{} = agent, ops, opts \\ []) when is_list(opts) do
    with {:ok, pod_state} <- TopologyState.fetch_state(agent),
         :ok <- ensure_mutation_idle(pod_state),
         {:ok, topology} <- TopologyState.fetch_topology(agent),
         {:ok, plan} <- Planner.plan(topology, ops) do
      mutation_state = %{id: plan.mutation_id, status: :running, report: plan.report, error: nil}

      {:ok,
       [
         StateOp.set_path([@pod_state_key, :topology], plan.final_topology),
         StateOp.set_path([@pod_state_key, :topology_version], plan.final_topology.version),
         StateOp.set_path([@pod_state_key, :mutation], mutation_state),
         ApplyMutation.new!(plan, opts)
       ]}
    end
  end

  defp ensure_mutation_idle(%{mutation: %{status: status}})
       when status in [:running, :queued] do
    {:error, :mutation_in_progress}
  end

  defp ensure_mutation_idle(_pod_state), do: :ok

  defp run_mutation(server, signal, await_timeout) do
    selector = fn %{agent: %{state: agent_state}} ->
      case get_in(agent_state, [@pod_state_key, :mutation, :status]) do
        :completed -> {:ok, get_in(agent_state, [@pod_state_key, :mutation, :report])}
        :failed -> {:error, get_in(agent_state, [@pod_state_key, :mutation, :error])}
        _ -> {:error, :mutation_not_settled}
      end
    end

    AgentServer.cast_and_await(server, signal, selector, timeout: await_timeout)
  end
end
