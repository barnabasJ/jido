defmodule Jido.Pod.Runtime do
  @moduledoc false

  alias Jido.Agent.Directive.SpawnManagedAgent
  alias Jido.Agent.InstanceManager
  alias Jido.AgentServer
  alias Jido.AgentServer.{ParentRef, State}
  alias Jido.AgentServer.Signal.ChildExit
  alias Jido.AgentServer.Signal.ChildStarted
  alias Jido.Pod.Mutable
  alias Jido.Pod.Mutation
  alias Jido.Pod.Topology
  alias Jido.Pod.Topology.Node
  alias Jido.Pod.TopologyState
  alias Jido.Signal

  defmodule View do
    @moduledoc """
    Narrow projection of `%Jido.AgentServer.State{}` used by `Pod.Runtime`'s
    internal helpers. Built once at the cross-process boundary (via the
    private `fetch_runtime_view/1`) or in-handler (via `view_from_state/2`);
    never refreshed in place.
    """

    @enforce_keys [:id, :registry, :partition, :jido, :agent_module, :topology, :pod_key]
    defstruct [:id, :registry, :partition, :jido, :agent_module, :topology, :pod_key]

    @type t :: %__MODULE__{
            id: String.t(),
            registry: module(),
            partition: term() | nil,
            jido: atom(),
            agent_module: module(),
            topology: Jido.Pod.Topology.t(),
            pod_key: term()
          }
  end

  defguardp is_node_name(name) when is_atom(name) or is_binary(name)

  @doc """
  Returns the pod's current topology + per-node runtime snapshots.
  """
  def nodes(server) do
    with {:ok, query} <- Signal.new("jido.pod.query.nodes", %{}, source: "/jido/pod/runtime"),
         {:ok, reply} <- Jido.Signal.Call.call(server, query) do
      case reply.type do
        "jido.pod.query.nodes.reply" -> {:ok, reply.data.nodes}
        "jido.pod.query.nodes.error" -> {:error, reply.data.reason}
      end
    end
  end

  @doc """
  Returns the pid of the named node if it's running.
  """
  def lookup_node(server, name) when is_node_name(name) do
    with {:ok, snapshots} <- nodes(server) do
      case Map.get(snapshots, name) do
        nil -> {:error, :unknown_node}
        %{running_pid: pid} when is_pid(pid) -> {:ok, pid}
        _snapshot -> :error
      end
    end
  end

  @doc """
  Ensures a named node is running by submitting an EnsureNode mutation
  through the signal-driven state machine and waiting for completion.
  """
  def ensure_node(server, name, opts \\ []) when is_node_name(name) and is_list(opts) do
    {ensure_opts, mutate_opts} = Keyword.split(opts, [:initial_state])

    case Mutable.mutate_and_wait(server, [Mutation.ensure_node(name, ensure_opts)], mutate_opts) do
      {:ok, report} ->
        case get_in(report, [Access.key!(:nodes), name]) do
          %{pid: pid} when is_pid(pid) -> {:ok, pid}
          _ -> lookup_node(server, name)
        end

      {:error, %{failures: failures} = report} ->
        case Map.get(failures, name) do
          nil -> {:error, report}
          reason -> {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Reconciles a pod by starting any eager nodes that aren't yet running.
  """
  def reconcile(server, opts \\ []) when is_list(opts) do
    with {:ok, eager_unrunning} <- eager_unrunning_nodes(server) do
      case Mutable.mutate_and_wait(
             server,
             Enum.map(eager_unrunning, &Mutation.ensure_node/1),
             opts
           ) do
        {:ok, report} ->
          {:ok, reconcile_report(report, eager_unrunning)}

        {:error, report} when is_map(report) ->
          {:error, reconcile_report(report, eager_unrunning)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp eager_unrunning_nodes(server) do
    case AgentServer.state(server, &eager_unrunning_selector/1) do
      {:ok, names} -> {:ok, names}
      {:error, _} = err -> err
    end
  end

  defp eager_unrunning_selector(%State{} = state) do
    with {:ok, topology} <- TopologyState.fetch_topology(state) do
      view = view_from_state(state, topology)

      names =
        topology.nodes
        |> Enum.filter(fn {_name, node} -> node.activation == :eager end)
        |> Enum.reject(fn {name, node} ->
          snapshot = build_node_snapshot(view, name, node)
          is_pid(snapshot.running_pid)
        end)
        |> Enum.map(&elem(&1, 0))

      {:ok, names}
    end
  end

  # Map a mutation report into the legacy reconcile report shape so existing
  # callers (notably Pod.get's `{:error, %{stage: :reconcile, ...}}` path)
  # continue to work.
  defp reconcile_report(%Jido.Pod.Mutation.Report{} = mreport, requested) do
    requested = Enum.uniq(requested)
    completed = mreport.started || []
    failures = mreport.failures || %{}
    failed = failures |> Map.keys() |> Enum.sort()

    %{
      requested: requested,
      waves: [],
      nodes: Map.get(mreport, :nodes, %{}),
      failures: failures,
      completed: completed,
      failed: failed,
      pending: []
    }
  end

  defp reconcile_report(report, requested) when is_map(report) do
    failures = Map.get(report, :failures, %{})

    %{
      requested: requested,
      waves: [],
      nodes: Map.get(report, :nodes, %{}),
      failures: failures,
      completed: Map.get(report, :started, []),
      failed: failures |> Map.keys() |> Enum.sort(),
      pending: []
    }
  end

  @doc """
  Synchronous teardown — directly kills each child pid. Bypasses the state
  machine intentionally; used during supervisor cleanup where we are not
  guaranteed a healthy mailbox.
  """
  @spec teardown_runtime(AgentServer.server(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def teardown_runtime(server, _opts \\ []) do
    with {:ok, view} <- fetch_runtime_view(server),
         {:ok, server_pid} <- resolve_runtime_server(server, view),
         {:ok, snapshots} <- nodes(server_pid) do
      requested = Map.keys(view.topology.nodes)

      stopped =
        for name <- requested,
            snapshot = Map.get(snapshots, name),
            is_map(snapshot),
            is_pid(snapshot.running_pid),
            do: name,
            into: []

      _ =
        Enum.each(snapshots, fn
          {_name, %{running_pid: pid}} when is_pid(pid) -> Process.exit(pid, :shutdown)
          _ -> :ok
        end)

      {:ok,
       %{
         requested: requested,
         waves: [],
         stopped: Enum.sort(stopped),
         failures: %{}
       }}
    end
  end

  @doc """
  Spawn or adopt one node. Pure I/O — does not modify `state.agent.state`.
  Returns `{:ok, state, pid}` for a fresh spawn, or `{:ok, state, :adopted}`
  when the node was already running. The natural `jido.agent.child.started`
  signal advances the mutation state machine.
  """
  @spec start_node(State.t(), Mutation.node_name(), keyword()) ::
          {:ok, State.t(), pid()}
          | {:ok, State.t(), :adopted}
          | {:error, State.t(), term()}
  def start_node(%State{} = state, name, opts \\ []) when is_node_name(name) and is_list(opts) do
    ancestry = Keyword.get(opts, :pod_ancestry, [state.agent_module])

    with {:ok, topology} <- TopologyState.fetch_topology(state),
         {:ok, node} <- fetch_node(topology, name),
         :ok <- ensure_runtime_supported(node, name, ancestry) do
      view = view_from_state(state, topology)
      snapshot = build_node_snapshot(view, name, node)

      cond do
        is_pid(snapshot.running_pid) ->
          adopt_existing(state, view, name, node, snapshot.running_pid)

        true ->
          spawn_new(state, view, name, node, opts)
      end
    end
    |> case do
      {:ok, _state, _result} = ok -> ok
      {:error, reason} -> {:error, state, reason}
      {:error, _state, _reason} = err -> err
    end
  end

  @doc """
  Send shutdown to one node's child. Pure I/O — does not modify
  `state.agent.state`. Returns `{:ok, state}`. For root-owned children
  the natural `jido.agent.child.exit` (from the pod's own monitor's
  DOWN) advances the state machine. For owner-owned children (where the
  pod doesn't hold the monitor) the stop is cast to the looked-up pid
  and a synthetic `jido.agent.child.exit` is dispatched immediately so
  the state machine still advances.
  """
  @spec stop_node(State.t(), Mutation.node_name(), term()) :: {:ok, State.t()}
  def stop_node(%State{} = state, name, reason \\ :shutdown) when is_node_name(name) do
    case Map.get(state.children, name) do
      %{pid: pid} when is_pid(pid) ->
        cast_stop(pid, state, reason)
        # Root child: pod holds the monitor. handle_child_down will
        # emit the natural jido.agent.child.exit when the pid actually
        # dies. State machine advances then.
        {:ok, state}

      _ ->
        stop_offboard(state, name, reason)
        {:ok, state}
    end
  end

  defp stop_offboard(%State{} = state, name, reason) do
    pid = lookup_offboard_pid(state, name)
    if is_pid(pid), do: cast_stop(pid, state, reason)

    # Owned-by-someone-else child or no-proc fallback. The pod doesn't
    # hold a monitor on this pid, so no natural child.exit will reach
    # MutateProgress. Synthesize one immediately so the state machine
    # advances.
    synthetic_reason = if is_pid(pid), do: reason, else: :no_proc
    _ = AgentServer.cast(self(), synthetic_child_exit(state, name, synthetic_reason))
    :ok
  end

  defp lookup_offboard_pid(%State{} = state, name) do
    # Try the live topology first (covers owned-not-removed nodes).
    pid_from_live = pid_via_topology(state, current_topology(state), name)

    if is_pid(pid_from_live) do
      pid_from_live
    else
      # Fall back to the in-flight plan's pre-removal topology so we can
      # locate the pid for nodes the same mutation is removing.
      pid_via_topology(state, plan_current_topology(state), name)
    end
  end

  defp current_topology(%State{} = state) do
    case TopologyState.fetch_topology(state) do
      {:ok, topology} -> topology
      _ -> nil
    end
  end

  defp plan_current_topology(%State{agent: %{state: agent_state}}) do
    case agent_state do
      %{pod: %{mutation: %{plan: %Jido.Pod.Mutation.Plan{current_topology: topology}}}} ->
        topology

      _ ->
        nil
    end
  end

  defp pid_via_topology(_state, nil, _name), do: nil

  defp pid_via_topology(%State{} = state, %Topology{} = topology, name) do
    case fetch_node(topology, name) do
      {:ok, node} ->
        view = view_from_state(state, topology)
        snapshot = build_node_snapshot(view, name, node)
        snapshot.running_pid

      _ ->
        nil
    end
  end

  defp cast_stop(pid, %State{} = state, reason) when is_pid(pid) do
    stop_signal =
      Signal.new!(
        "jido.agent.stop",
        %{reason: normalize_stop_reason(reason)},
        source: "/pod/#{state.id}"
      )

    _ = AgentServer.cast(pid, stop_signal)
    :ok
  end

  defp adopt_existing(%State{} = state, %View{} = view, name, %Node{} = node, pid)
       when is_pid(pid) do
    # Re-attach as parent so the child's parent_ref points back here.
    {:ok, parent_ref} = build_parent_ref(self(), view, name, node.meta)
    _ = AgentServer.adopt_parent(pid, parent_ref)

    # Cast a synthetic child.started so the state machine advances and
    # `maybe_track_child_started/2` registers the pid in `state.children`.
    synthetic =
      ChildStarted.new!(
        %{
          parent_id: state.id,
          child_id: child_id(view, name),
          child_partition: view.partition,
          child_module: child_module(node),
          tag: name,
          pid: pid,
          meta: node.meta
        },
        source: "/agent/#{state.id}"
      )

    _ = AgentServer.cast(self(), synthetic)
    {:ok, state, :adopted}
  end

  defp spawn_new(%State{} = state, %View{} = view, name, %Node{} = node, opts) do
    initial_state = node_initial_state(name, node, opts)
    key = node_key(view, name)
    owner = owner_name(view.topology, name)

    with {:ok, parent_pid} <- resolve_parent_pid(self(), view, owner),
         {:ok, parent_ref} <- build_parent_ref(parent_pid, view, name, node.meta),
         {:ok, pid} <- spawn_via_manager(name, node, key, parent_ref, view, initial_state) do
      # For root-owned nodes, the child's natural notify_parent_of_startup
      # arrives at the pod and triggers both maybe_track_child_started/2
      # (state.children update) and MutateProgress (state machine).
      #
      # For owner-owned nodes, the natural child.started goes to the
      # owner. The pod synthesizes a child.started with parent_id set to
      # the owner's id — maybe_track_child_started/2 skips (parent_id
      # mismatch) but MutateProgress still fires (it matches by tag).
      maybe_synthesize_child_started(state, view, name, node, pid, owner)
      maybe_kick_nested_reconcile(node, pid, opts)
      {:ok, state, pid}
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp maybe_synthesize_child_started(
         %State{} = state,
         %View{} = view,
         name,
         %Node{} = node,
         pid,
         owner
       ) do
    if owner == nil do
      :ok
    else
      synthetic =
        ChildStarted.new!(
          %{
            parent_id: node_id(view, owner),
            child_id: child_id(view, name),
            child_partition: view.partition,
            child_module: child_module(node),
            tag: name,
            pid: pid,
            meta: node.meta
          },
          source: "/agent/#{state.id}"
        )

      _ = AgentServer.cast(self(), synthetic)
      :ok
    end
  end

  defp spawn_via_manager(name, %Node{} = node, key, parent_ref, %View{} = view, initial_state) do
    directive = %SpawnManagedAgent{
      namespace: node.manager,
      key: key,
      tag: name,
      initial_state: initial_state,
      parent: parent_ref,
      agent_opts: [partition: view.partition]
    }

    try do
      SpawnManagedAgent.execute(directive, view)
    rescue
      error in [ArgumentError, KeyError] ->
        {:error,
         Jido.Error.validation_error(
           "Failed to acquire pod node from InstanceManager.",
           details: %{manager: node.manager, key: key, error: Exception.message(error)}
         )}
    end
  end

  # When a kind: :pod node spawns, fire-and-forget a reconcile mutation so
  # its eager children come up. Without this the parent's mutation finishes
  # the moment child.started arrives, but the nested pod is empty.
  defp maybe_kick_nested_reconcile(%Node{kind: :pod}, nested_pid, _opts)
       when is_pid(nested_pid) do
    spawn(fn ->
      _ = AgentServer.await_ready(nested_pid)
      _ = reconcile(nested_pid, [])
    end)

    :ok
  end

  defp maybe_kick_nested_reconcile(_node, _pid, _opts), do: :ok

  defp synthetic_child_exit(%State{} = state, name, reason) do
    ChildExit.new!(
      %{tag: name, pid: nil, reason: reason},
      source: "/agent/#{state.id}"
    )
  end

  defp child_module(%Node{module: module}) when is_atom(module) and not is_nil(module), do: module
  defp child_module(_node), do: nil

  defp child_id(%View{} = view, name) do
    view |> node_key(name) |> key_to_id()
  end

  defp normalize_stop_reason(:normal), do: :normal
  defp normalize_stop_reason(:shutdown), do: :shutdown
  defp normalize_stop_reason({:shutdown, _} = reason), do: reason
  defp normalize_stop_reason(reason), do: {:shutdown, reason}

  defp fetch_node(%Topology{} = topology, name) when is_node_name(name) do
    case Topology.fetch_node(topology, name) do
      {:ok, %Node{} = node} -> {:ok, node}
      :error -> {:error, :unknown_node}
    end
  end

  defp ensure_runtime_supported(%Node{kind: :agent}, _name, _ancestry), do: :ok

  defp ensure_runtime_supported(
         %Node{kind: :pod, module: module, manager: manager},
         name,
         ancestry
       )
       when is_atom(module) do
    with :ok <- ensure_pod_module(module),
         :ok <- ensure_pod_manager_module(manager, module),
         :ok <- ensure_pod_not_recursive(module, name, ancestry) do
      :ok
    end
  end

  defp ensure_runtime_supported(%Node{} = node, name, _ancestry) do
    {:error,
     Jido.Error.validation_error(
       "Pod runtime only supports kind: :agent and kind: :pod nodes today.",
       details: %{name: name, kind: node.kind}
     )}
  end

  defp ensure_pod_not_recursive(module, name, ancestry) when is_list(ancestry) do
    if module in ancestry do
      {:error,
       Jido.Error.validation_error(
         "Recursive pod runtime is not supported for the current pod ancestry.",
         details: %{module: module, ancestry: ancestry, node: name}
       )}
    else
      walk_pod_topology(module, [module | ancestry], name)
    end
  end

  defp walk_pod_topology(module, ancestry, original_name) do
    case fetch_pod_topology(module) do
      {:ok, topology} ->
        Enum.reduce_while(topology.nodes, :ok, fn
          {_name, %Node{kind: :pod, module: nested_module}}, :ok ->
            cond do
              nested_module == nil ->
                {:cont, :ok}

              nested_module in ancestry ->
                {:halt, recursion_error(nested_module, ancestry, original_name)}

              true ->
                case walk_pod_topology(nested_module, [nested_module | ancestry], original_name) do
                  :ok -> {:cont, :ok}
                  err -> {:halt, err}
                end
            end

          _other, :ok ->
            {:cont, :ok}
        end)

      _ ->
        :ok
    end
  end

  defp fetch_pod_topology(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        if function_exported?(module, :topology, 0), do: {:ok, module.topology()}, else: :error

      _ ->
        :error
    end
  end

  defp recursion_error(module, ancestry, name) do
    {:error,
     Jido.Error.validation_error(
       "Recursive pod runtime is not supported for the current pod ancestry.",
       details: %{module: module, ancestry: ancestry, node: name}
     )}
  end

  defp ensure_pod_module(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _loaded} ->
        cond do
          function_exported?(module, :pod?, 0) and module.pod?() ->
            case TopologyState.pod_plugin_instance(module) do
              {:ok, _instance} -> :ok
              {:error, reason} -> {:error, reason}
            end

          true ->
            {:error,
             Jido.Error.validation_error(
               "Pod runtime requires kind: :pod nodes to reference a pod module.",
               details: %{module: module}
             )}
        end

      {:error, reason} ->
        {:error,
         Jido.Error.validation_error(
           "Pod runtime could not load the module for a kind: :pod node.",
           details: %{module: module, reason: reason}
         )}
    end
  end

  defp ensure_pod_manager_module(manager, module) when is_atom(manager) and is_atom(module) do
    case InstanceManager.agent_module(manager) do
      {:ok, ^module} ->
        :ok

      {:ok, actual_module} ->
        {:error,
         Jido.Error.validation_error(
           "Pod runtime requires the nested pod manager to manage the declared pod module.",
           details: %{manager: manager, module: module, actual_module: actual_module}
         )}

      {:error, :not_found} ->
        {:error,
         Jido.Error.validation_error(
           "Pod runtime could not resolve the nested pod manager.",
           details: %{manager: manager, module: module}
         )}
    end
  end

  @doc """
  Builds per-node runtime snapshots (status, pid, ownership, key) keyed by
  node name. Shared helper for `nodes/1` and `Jido.Pod.Actions.QueryNodes`.
  """
  @spec build_node_snapshots(State.t(), Topology.t()) :: map()
  def build_node_snapshots(%State{} = state, %Topology{} = topology) do
    view = view_from_state(state, topology)

    Map.new(topology.nodes, fn {name, node} ->
      {name, build_node_snapshot(view, name, node)}
    end)
  end

  defp build_node_snapshot(%View{} = view, name, node) do
    node =
      case node do
        %Node{} = existing_node -> existing_node
        _other -> view.topology.nodes[name]
      end

    key = node_key(view, name)
    running_pid = running_child_pid(node.manager, key, partition: view.partition)
    owner = owner_name(view.topology, name)
    expected_parent = expected_parent_ref(view, name, owner)
    actual_parent = actual_parent_ref(view, name)
    adopted? = parent_matches?(actual_parent, expected_parent)

    status =
      cond do
        is_pid(running_pid) and adopted? -> :adopted
        is_pid(running_pid) and is_map(actual_parent) -> :misplaced
        is_pid(running_pid) -> :running
        true -> :stopped
      end

    %{
      node: node,
      key: key,
      pid: running_pid,
      running_pid: running_pid,
      adopted_pid: if(adopted?, do: running_pid, else: nil),
      owner: owner,
      expected_parent: expected_parent,
      actual_parent: actual_parent,
      adopted?: adopted?,
      status: status
    }
  end

  defp running_child_pid(manager, key, opts) do
    try do
      case InstanceManager.lookup(manager, key, opts) do
        {:ok, pid} -> pid
        :error -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp owner_name(%Topology{} = topology, name) do
    case Topology.owner_of(topology, name) do
      {:ok, owner} -> owner
      _other -> nil
    end
  end

  defp expected_parent_ref(%View{} = view, name, nil) do
    %{scope: :pod, name: nil, id: view.id, partition: view.partition, tag: name}
  end

  defp expected_parent_ref(%View{} = view, name, owner_name)
       when is_node_name(owner_name) do
    %{
      scope: :node,
      name: owner_name,
      id: node_id(view, owner_name),
      partition: view.partition,
      tag: name
    }
  end

  defp parent_matches?(
         %{id: actual_id, partition: actual_partition, tag: actual_tag},
         %{id: expected_id, partition: expected_partition, tag: expected_tag}
       ) do
    actual_id == expected_id and actual_partition == expected_partition and
      actual_tag == expected_tag
  end

  defp parent_matches?(_actual_parent, _expected_parent), do: false

  defp actual_parent_ref(%View{} = view, name) when is_node_name(name) do
    case Jido.parent_binding(view.jido, node_id(view, name), partition: view.partition) do
      {:ok, %{parent_id: parent_id, parent_partition: parent_partition, tag: tag}} ->
        parent_partition = parent_partition || view.partition

        %{
          id: parent_id,
          partition: parent_partition,
          pid: resolve_parent_runtime_pid(view, parent_id, parent_partition),
          tag: tag
        }

      :error ->
        nil
    end
  end

  defp resolve_parent_runtime_pid(
         %View{id: view_id, registry: registry, partition: partition},
         parent_id,
         parent_partition
       )
       when parent_id == view_id do
    AgentServer.whereis(registry, view_id, partition: parent_partition || partition)
  end

  defp resolve_parent_runtime_pid(%View{} = view, parent_id, parent_partition)
       when is_binary(parent_id) do
    case Enum.find(view.topology.nodes, fn {candidate_name, _node} ->
           node_id(view, candidate_name) == parent_id
         end) do
      {owner_name, %Node{manager: manager}} ->
        running_child_pid(manager, node_key(view, owner_name), partition: parent_partition)

      nil ->
        Jido.whereis(view.jido, parent_id, partition: parent_partition)
    end
  end

  defp build_parent_ref(parent_pid, %View{} = view, name, meta) do
    parent_id = resolve_parent_id(parent_pid, view)

    {:ok,
     ParentRef.new!(%{
       pid: parent_pid,
       id: parent_id,
       partition: view.partition,
       tag: name,
       meta: meta
     })}
  end

  defp resolve_parent_id(parent_pid, %View{id: view_id}) do
    if parent_pid == self() do
      view_id
    else
      case AgentServer.state(parent_pid, &id_selector/1) do
        {:ok, id} -> id
        {:error, _} -> view_id
      end
    end
  end

  defp id_selector(%State{id: id}), do: {:ok, id}

  # Picks the parent pid for a child node. `owner` is `nil` for root-owned
  # nodes (the pod itself is the parent) or the owner topology node name
  # otherwise — in which case the owner's running pid is looked up.
  defp resolve_parent_pid(server_pid, _view, nil), do: {:ok, server_pid}

  defp resolve_parent_pid(_server_pid, %View{} = view, owner_name)
       when is_atom(owner_name) or is_binary(owner_name) do
    owner_node = view.topology.nodes[owner_name]

    if owner_node do
      owner_key = node_key(view, owner_name)
      pid = running_child_pid(owner_node.manager, owner_key, partition: view.partition)

      if is_pid(pid) do
        {:ok, pid}
      else
        {:error,
         Jido.Error.validation_error(
           "Cannot ensure pod node before its logical owner is running.",
           details: %{owner: owner_name}
         )}
      end
    else
      {:error, :unknown_node}
    end
  end

  defp node_initial_state(_name, %Node{} = node, opts) do
    Keyword.get(opts, :initial_state, node.initial_state)
  end

  defp resolve_runtime_server(server, %View{id: id, registry: registry, partition: partition}) do
    if is_pid(server) and Process.alive?(server) do
      {:ok, server}
    else
      case AgentServer.whereis(registry, id, partition: partition) do
        pid when is_pid(pid) -> {:ok, pid}
        nil -> {:error, :not_found}
      end
    end
  end

  # Cross-process boundary: builds a `Pod.Runtime.View` via a tailored
  # selector that runs in the agent process. The full `%State{}` never
  # crosses the boundary — the selector projects exactly the fields the
  # runtime helpers need (and resolves the live topology via
  # `TopologyState.fetch_topology/1` while still in-process).
  defp fetch_runtime_view(server) do
    AgentServer.state(server, fn s ->
      with {:ok, topology} <- TopologyState.fetch_topology(s) do
        {:ok,
         %View{
           id: s.id,
           registry: s.registry,
           partition: s.partition,
           jido: s.jido,
           agent_module: s.agent_module,
           topology: topology,
           pod_key: pod_key_from_state(s)
         }}
      end
    end)
  end

  # In-handler boundary: the `%State{}` is live by definition, so a selector
  # round-trip would be wasteful. Constructs the view inline.
  @spec view_from_state(State.t(), Topology.t()) :: View.t()
  defp view_from_state(%State{} = state, %Topology{} = topology) do
    %View{
      id: state.id,
      registry: state.registry,
      partition: state.partition,
      jido: state.jido,
      agent_module: state.agent_module,
      topology: topology,
      pod_key: pod_key_from_state(state)
    }
  end

  defp pod_key_from_state(%State{lifecycle: %{pool_key: pool_key}}) when not is_nil(pool_key),
    do: pool_key

  defp pod_key_from_state(%State{id: id}), do: id

  defp node_key(%View{} = view, name) do
    {view.agent_module, view.pod_key, name}
  end

  defp node_id(%View{} = view, name) do
    view |> node_key(name) |> key_to_id()
  end

  defp key_to_id(key) do
    digest =
      key
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "key_" <> digest
  end
end
