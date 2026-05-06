defmodule Jido.Slices.Pod do
  @moduledoc """
  Reserved slice + Spark extension for pod-extended agents.

  A pod is a `Jido.Agent` that lists `Jido.Slices.Pod` in its `extensions:` (so
  the contributed `pod do topology … end` block opens) and mounts
  `Jido.Slices.Pod` at `:pod` in `slices do … end`:

      defmodule MyApp.Fulfillment do
        use Jido.Agent, extensions: [Jido.Slices.Pod]

        agent do
          name "fulfillment"
        end

        slices do
          slice :pod, Jido.Slices.Pod
        end

        pod do
          topology %{
            warehouse: %{agent: MyApp.Warehouse, manager: :fulfillment_warehouse, activation: :eager},
            shipping:  %{agent: MyApp.Shipping,  manager: :fulfillment_shipping,  activation: :eager}
          }
        end
      end

  To swap in a custom pod plugin, mount a different module at `:pod`:
  `slices do slice :pod, MyCustomPodPlugin end` (and omit
  `extensions: [Jido.Slices.Pod]` if the custom plugin owns its own contributed
  section). The replacement must advertise capability `:pod`.

  ## Singleton — mount only once

  `Jido.Slices.Pod` is meant to be a singleton at `:pod`. Multi-instance fan-out
  (the runtime semantics that lets `slice :slack_a, SlackPlugin;
  slice :slack_b, SlackPlugin` dispatch one signal across both mounts) is
  framework-uniform — it would technically apply to `Jido.Slices.Pod` too. But
  Pod's lifecycle handlers (`MutateProgress` reacts to
  `jido.agent.child.started` / `jido.agent.child.exit`) bind 1:1 to the
  child processes managed by a single pod manager. If you mount Pod twice
  the framework will fan those handlers out across both mounts and the
  mutation tracking will go wrong (each mount sees lifecycle signals for
  children that don't belong to it).

  The framework does not enforce single-mount because singleton-ness isn't
  a uniform property of slices. Don't mount `Jido.Slices.Pod` twice.
  """

  alias Jido.Agent
  alias Jido.Agent.InstanceManager
  alias Jido.AgentServer
  alias Jido.AgentServer.State
  alias Jido.Slices.Pod.Actions.Mutate, as: MutateAction
  alias Jido.Slices.Pod.Actions.MutateProgress
  alias Jido.Slices.Pod.Actions.QueryNodes
  alias Jido.Slices.Pod.Actions.QueryTopology
  alias Jido.Slices.Pod.Mutable
  alias Jido.Slices.Pod.Mutation
  alias Jido.Slices.Pod.Mutation.Report
  alias Jido.Slices.Pod.Runtime
  alias Jido.Slices.Pod.Topology
  alias Jido.Slices.Pod.Topology.Node
  alias Jido.Slices.Pod.TopologyState

  @capability :pod

  @type node_status :: :adopted | :running | :misplaced | :stopped
  @type ensure_source :: :adopted | :running | :started
  @type node_name :: Topology.node_name()

  @type node_snapshot :: %{
          node: Node.t(),
          key: term(),
          pid: pid() | nil,
          running_pid: pid() | nil,
          adopted_pid: pid() | nil,
          owner: node_name() | nil,
          expected_parent: map(),
          actual_parent: map() | nil,
          adopted?: boolean(),
          status: node_status()
        }

  @type ensure_result :: %{
          pid: pid(),
          source: ensure_source(),
          owner: node_name() | nil,
          parent: :pod | node_name()
        }

  @type reconcile_report :: %{
          requested: [node_name()],
          waves: [[node_name()]],
          nodes: %{node_name() => ensure_result()},
          failures: %{node_name() => term()},
          completed: [node_name()],
          failed: [node_name()],
          pending: [node_name()]
        }

  @type mutation_report :: Report.t()

  # ──────────────────────────────────────────────────────────────────
  # Slice DSL — owns the :pod slice key in agent state
  # ──────────────────────────────────────────────────────────────────

  use Jido.Slice

  slice do
    name "pod"

    schema Zoi.object(%{
             topology: Zoi.any(description: "Resolved pod topology.") |> Zoi.optional(),
             topology_version:
               Zoi.integer(description: "Resolved topology version.") |> Zoi.default(1),
             mutation:
               Zoi.object(%{
                 id: Zoi.string(description: "In-flight mutation id.") |> Zoi.optional(),
                 status: Zoi.atom(description: "Mutation status.") |> Zoi.default(:idle),
                 plan: Zoi.any(description: "Mutation plan struct.") |> Zoi.optional(),
                 phase: Zoi.any(description: "State machine phase.") |> Zoi.default(:idle),
                 awaiting: Zoi.any(description: "Awaiting kind + names set.") |> Zoi.optional(),
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
           })
  end

  signal_routes do
    route "pod.mutate", MutateAction
    route "jido.pod.query.nodes", QueryNodes
    route "jido.pod.query.topology", QueryTopology
    route "jido.agent.child.started", MutateProgress
    route "jido.agent.child.exit", MutateProgress
  end

  capabilities do
    capability @capability
  end

  # ──────────────────────────────────────────────────────────────────
  # Spark extension — contributes the `pod do topology … end` section
  # ──────────────────────────────────────────────────────────────────

  @pod_section %Spark.Dsl.Section{
    name: :pod,
    describe: "Pod topology and runtime options.",
    schema: [
      topology: [
        type: :any,
        default: %{},
        doc:
          "Map of node names to node specs, or a `%Jido.Slices.Pod.Topology{}` struct " <>
            "describing the pod's canonical child agents."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@pod_section],
    transformers: [
      Jido.Slices.Pod.Transformers.RegisterContribution,
      Jido.Slices.Pod.Transformers.ResolveTopology
    ]

  # ──────────────────────────────────────────────────────────────────
  # Capability + slice state builder
  # ──────────────────────────────────────────────────────────────────

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
    case Jido.Slices.Pod.Info.pod_topology(agent_module) do
      {:ok, %Topology{} = topology} ->
        build_state(topology, overrides)

      _ ->
        {:error,
         Jido.Error.validation_error(
           "#{inspect(agent_module)} is not a pod-extended agent (no resolved topology)."
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

  # ──────────────────────────────────────────────────────────────────
  # Runtime helpers (unchanged signatures and semantics)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Gets a pod instance through the given `InstanceManager` and immediately
  reconciles eager nodes.

  This is the default happy path for pod lifecycle access. Call
  `Jido.Agent.InstanceManager.get/3` directly if you need lower-level control
  over reconciliation timing.
  """
  @spec get(atom(), term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get(manager, key, opts \\ []) when is_atom(manager) and is_list(opts) do
    with {:ok, pod_pid} <- InstanceManager.get(manager, key, opts),
         :ok <- AgentServer.await_ready(pod_pid) do
      case reconcile(pod_pid) do
        {:ok, _started} ->
          {:ok, pod_pid}

        {:error, reason} ->
          {:error, %{stage: :reconcile, pod: pod_pid, reason: reason}}
      end
    end
  end

  @doc """
  Returns the reserved pod slice instance for a pod-extended agent module.
  """
  @spec pod_slice_instance(module()) :: {:ok, Jido.Slice.Instance.t()} | {:error, term()}
  defdelegate pod_slice_instance(agent_module), to: TopologyState

  @doc """
  Fetches pod slice state from an agent or server state.
  """
  @spec fetch_state(Agent.t() | State.t()) :: {:ok, map()} | {:error, term()}
  defdelegate fetch_state(agent_or_state), to: TopologyState

  @doc """
  Fetches the canonical topology from a module, agent, or running pod server.
  """
  @spec fetch_topology(module() | Agent.t() | State.t() | AgentServer.server()) ::
          {:ok, Topology.t()} | {:error, term()}
  defdelegate fetch_topology(source), to: TopologyState

  @doc """
  Replaces the persisted topology snapshot in a pod agent.

  Structural topology changes advance `topology.version`; no-op replacements
  preserve the current version.
  """
  @spec put_topology(Agent.t(), Topology.t()) :: {:ok, Agent.t()} | {:error, term()}
  defdelegate put_topology(agent, topology), to: TopologyState

  @doc """
  Applies a pure topology transformation to a pod agent.

  Structural topology changes advance `topology.version`; no-op updates preserve
  the current version.
  """
  @spec update_topology(
          Agent.t(),
          (Topology.t() -> Topology.t() | {:ok, Topology.t()} | {:error, term()})
        ) ::
          {:ok, Agent.t()} | {:error, term()}
  defdelegate update_topology(agent, fun), to: TopologyState

  @doc """
  Submits a topology mutation to a running pod and returns immediately with
  a queued ack — does **not** wait for the mutation to complete.

  Returns `{:ok, %{mutation_id: id, queued: true}}` once the action's slice
  return has set the pod's mutation slice. The action's
  `ensure_mutation_idle/1` rejection (`{:error, :mutation_in_progress}`) and
  any planner validation errors (`{:error, %Jido.Error{}}`) are delivered
  through the framework's tagged-tuple ack — callers do not encode failure
  branches in the default selector.

  For the post-completion mutation report, use `mutate_and_wait/3`.

  `server` follows the same resolution rules as `Jido.AgentServer.state/3` and
  `Jido.AgentServer.call/4`. Pass the running pod pid, a locally registered
  server name, or another resolvable runtime server reference. Raw string ids
  still require explicit registry lookup before use.

  ## Options

  - `:await_timeout` (or `:timeout`) — ms to wait for the queued ack
    (default `:timer.seconds(30)`).
  - `:selector` — override the default queued-ack selector. Power users only;
    most callers want the default `%{mutation_id: id, queued: true}` projection.
  """
  @spec mutate(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
          {:ok, %{mutation_id: String.t(), queued: true}} | {:error, term()}
  defdelegate mutate(server, ops, opts \\ []), to: Mutable

  @doc """
  Submits a topology mutation and waits for the mutation slice to reach a
  terminal status, returning the completion report (or failure error).

  Wraps `mutate/3` with the subscribe-before-cast pattern: subscribes
  to `jido.agent.child.*` with a selector that reads `pod.mutation` and
  matches by `mutation.id` **before** issuing the cast.
  The state machine flips `mutation.status` to `:completed`/`:failed` when
  the last awaited child
  lifecycle signal arrives; the subscriber's selector fires on that same
  signal and delivers the terminal report. There is no synthetic
  `jido.pod.mutate.completed`/`.failed` signal — the slice is the
  contract.

  Returns `{:ok, mutation_report()}` on success or `{:error, term()}` on
  any failure path (action rejection, planner error, runtime materialization
  failure, or `:timeout`).
  """
  @spec mutate_and_wait(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
          {:ok, mutation_report()} | {:error, term()}
  defdelegate mutate_and_wait(server, ops, opts \\ []), to: Mutable

  @doc """
  Builds the new pod slice value and runtime side-effect directives for an
  in-turn pod mutation.
  """
  @spec mutation_effects(Agent.t(), [Mutation.t() | term()], keyword()) ::
          {:ok, map(), [struct()]} | {:error, term()}
  defdelegate mutation_effects(agent, ops, opts \\ []), to: Mutable

  @doc """
  Returns runtime snapshots for every node in a running pod.
  """
  @spec nodes(AgentServer.server()) :: {:ok, %{node_name() => node_snapshot()}} | {:error, term()}
  defdelegate nodes(server), to: Runtime

  @doc """
  Looks up a node's live process if it is currently running.
  """
  @spec lookup_node(AgentServer.server(), node_name()) :: {:ok, pid()} | :error | {:error, term()}
  defdelegate lookup_node(server, name), to: Runtime

  @doc """
  Ensures a named node is running and adopted into the pod manager.
  """
  @spec ensure_node(AgentServer.server(), node_name(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  defdelegate ensure_node(server, name, opts \\ []), to: Runtime

  @doc """
  Ensures all eager nodes are running and adopted into the pod manager.
  """
  @spec reconcile(AgentServer.server(), keyword()) ::
          {:ok, reconcile_report()} | {:error, reconcile_report()}
  defdelegate reconcile(server, opts \\ []), to: Runtime
end
