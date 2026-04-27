defmodule Jido.Pod.Plugin do
  @moduledoc """
  Default singleton slice for pod-wrapped agents.

  Owns the `:pod` slice key in agent state. Persists the resolved topology
  snapshot as ordinary slice state so existing `Persist` and `Storage`
  adapters keep working unchanged.

  ## Initial state

  Schema defaults seed the slice with `%{topology: nil, topology_version: 1,
  mutation: %{...}, metadata: %{}}`. The owning agent module (typically built
  via `use Jido.Pod`) is responsible for filling in `:topology` from its
  declared topology — usually by passing
  `state: %{pod: %{topology: ..., topology_version: ...}}` to `Jido.Agent.new/1`.
  """

  alias Jido.Pod.Actions.Mutate, as: MutateAction
  alias Jido.Pod.Actions.MutateProgress
  alias Jido.Pod.Actions.QueryNodes
  alias Jido.Pod.Actions.QueryTopology
  alias Jido.Pod.Topology

  @path :pod
  @capability :pod

  use Jido.Slice,
    name: "pod",
    path: @path,
    actions: [MutateAction, MutateProgress, QueryNodes, QueryTopology],
    signal_routes: [
      {"mutate", MutateAction},
      {"jido.pod.query.nodes", QueryNodes},
      {"jido.pod.query.topology", QueryTopology},
      {"jido.agent.child.started", MutateProgress},
      {"jido.agent.child.exit", MutateProgress}
    ],
    schema:
      Zoi.object(%{
        topology: Zoi.any(description: "Resolved pod topology.") |> Zoi.optional(),
        topology_version:
          Zoi.integer(description: "Resolved topology version.") |> Zoi.default(1),
        mutation:
          Zoi.object(%{
            id: Zoi.string(description: "In-flight mutation id.") |> Zoi.optional(),
            status: Zoi.atom(description: "Mutation status.") |> Zoi.default(:idle),
            plan: Zoi.any(description: "Mutation plan struct.") |> Zoi.optional(),
            phase:
              Zoi.any(description: "State machine phase.") |> Zoi.default(:idle),
            awaiting:
              Zoi.any(description: "Awaiting kind + names set.") |> Zoi.optional(),
            report: Zoi.any(description: "Latest mutation report.") |> Zoi.optional(),
            error: Zoi.any(description: "Latest mutation error/report.") |> Zoi.optional()
          })
          |> Zoi.default(%{
            id: nil,
            status: :idle,
            plan: nil,
            phase: :idle,
            awaiting: nil,
            report: nil,
            error: nil
          }),
        metadata:
          Zoi.map(description: "Pod-level runtime metadata owned by the slice.")
          |> Zoi.default(%{})
      }),
    capabilities: [@capability],
    singleton: true

  @doc false
  @spec capability() :: atom()
  def capability, do: @capability

  @doc """
  Builds the canonical default state for a pod slice.
  """
  @spec build_state(module() | Topology.t(), map()) :: {:ok, map()} | {:error, term()}
  def build_state(%Topology{} = topology, overrides) when is_map(overrides) do
    {:ok,
     %{
       topology: topology,
       topology_version: topology.version,
       mutation: %{
         id: nil,
         status: :idle,
         plan: nil,
         phase: :idle,
         awaiting: nil,
         report: nil,
         error: nil
       },
       metadata: %{}
     }
     |> deep_merge(overrides)}
  end

  def build_state(agent_module, overrides) when is_atom(agent_module) and is_map(overrides) do
    cond do
      function_exported?(agent_module, :topology, 0) ->
        build_state(agent_module.topology(), overrides)

      true ->
        {:error,
         Jido.Error.validation_error(
           "#{inspect(agent_module)} does not export topology/0 required by pod slices."
         )}
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end
end
