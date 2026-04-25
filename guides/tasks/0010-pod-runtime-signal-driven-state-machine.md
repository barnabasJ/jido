# Task 0010 — Pod runtime: signal-driven state machine; delete wave orchestration

- Implements: [ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md) Phase 2 — runtime simplification + state machine
- Depends on: [task 0009](0009-pod-mutate-cast-await-api.md) (caller API already cast_and_await + lifecycle signal-shaped)
- Blocks: nothing — this is the terminal task for ADR 0017
- Leaves tree: **green**

## Goal

Replace `Jido.Pod.Runtime`'s wave-orchestrating machinery (~1100 lines) with a signal-driven state machine. Mutations decompose into a stream of fast directive applications coordinated by `jido.agent.child.started` and `jido.agent.child.exit` lifecycle signals. The pod's mailbox is never blocked by mutation work.

After this task:

- `Runtime` shrinks from ~1400 lines to ~250 — only read-side helpers (`nodes/1`, `lookup_node/2`, `build_node_snapshots/2`) and two new primitives (`start_node/2`, `stop_node/2`).
- `ApplyMutation` directive is deleted. Its work is replaced by `StartNode` / `StopNode` directives plus state-machine handlers in the pod plugin.
- `Pod.Actions.Mutate.run/4` plans the mutation and emits the first wave of `StartNode`/`StopNode` directives; the action returns immediately.
- The pod plugin gets two new signal_routes (`jido.agent.child.started`, `jido.agent.child.exit`) bound to a small action that advances the mutation state machine.

The mutation slice gains two fields per [ADR 0017 §1](../adr/0017-pod-mutations-are-signal-driven.md):

```elixir
mutation = %{
  id: id,
  status: :idle | :running | :completed | :failed,
  plan: %{stop_waves: [...], start_waves: [...]} | nil,
  phase: :idle | {:stop_wave, n} | {:start_wave, n} | :complete,
  awaiting: %{kind: :exit | :started, names: MapSet.t()} | nil,
  report: report | nil,
  error: any | nil
}
```

## Files to modify

### `lib/jido/pod/runtime.ex`

**Delete entirely:**

- `execute_mutation_plan/3` and its helpers
- `execute_runtime_plan/6`, `execute_runtime_plan_locally/5`, `execute_stop_waves/8`
- `stop_planned_node/8`, `dispatch_stop_to_parent/7`, `direct_stop_child/4`, `await_process_exit/2`
- `ensure_planned_node/7`, `ensure_planned_node_locally/6`, `do_ensure_planned_node{,_locally}`, `ensure_planned_agent_node{,_locally}`, `ensure_planned_pod_node{,_locally}`
- `merge_wave_results/4`, `complete_mutation_report/3`, `empty_reconcile_report/0` and other wave-shape helpers
- The synchronous `execute_runtime_plan_locally`-flavored variants of all of the above
- `teardown_runtime/2` becomes a thin wrapper over a generated full-stop mutation (or kept verbatim if test surface still depends on it; prefer wrapping)

**Keep:**

- `nodes/1` — query via signal
- `lookup_node/2` — query via signal
- `build_node_snapshots/2` and `build_node_snapshot/4` — used by `Actions.QueryNodes`
- `ensure_runtime_supported/2`, `ensure_pod_module/1`, `ensure_pod_manager_module/2` — validation helpers
- `node_initial_state/4`, `node_key/2` — small data helpers
- `resolve_runtime_server/2`, `resolve_parent_pid/4`, `build_parent_ref/5`, `node_event_metadata/4` — helpers used by the new primitives

**Reshape `ensure_node/3` and `reconcile/2`** to delegate to the new state machine:

```elixir
def ensure_node(server, name, opts \\ []) do
  Pod.Mutable.mutate(server, [Mutation.add_node(name)], opts)
end

def reconcile(server, opts \\ []) do
  Pod.Mutable.mutate(server, reconcile_ops(server), opts)
end
```

`reconcile_ops/1` reads the topology, computes which eager nodes aren't running, returns the `add_node` ops list. This keeps `ensure_node` and `reconcile` on the same code path as `mutate` — one state machine, no parallel orchestration.

**Add two primitives:**

```elixir
@doc """
Start one node. Cheap: spawn-or-adopt + return. Does not wait for `:post_init`.
The resulting `jido.agent.child.started` signal advances the mutation state machine.
"""
@spec start_node(State.t(), node_name(), keyword()) ::
        {:ok, State.t(), pid()} | {:error, State.t(), term()}
def start_node(%State{} = state, name, opts \\ []) do
  with {:ok, topology} <- TopologyState.fetch_topology(state),
       {:ok, node} <- fetch_node(topology, name),
       :ok <- ensure_runtime_supported(node, name) do
    snapshot = build_node_snapshot(state, topology, name, node)

    cond do
      is_pid(snapshot.running_pid) ->
        # Adoption: existing pid; track it and synthesize a child.started signal so the
        # state machine advances uniformly.
        adopt_existing(state, name, node, snapshot.running_pid)

      true ->
        spawn_new(state, topology, name, node, opts)
    end
  end
end

@doc """
Send shutdown to one node's child. Returns immediately; the resulting
`jido.agent.child.exit` advances the state machine.
"""
@spec stop_node(State.t(), node_name(), term()) :: {:ok, State.t()} | {:error, State.t(), term()}
def stop_node(%State{} = state, name, reason \\ :shutdown) do
  case Map.get(state.children, name) do
    %ChildInfo{pid: pid} when is_pid(pid) ->
      Process.exit(pid, reason)
      {:ok, state}

    _ ->
      # Nothing to stop; emit a synthetic child.exit so the state machine still advances.
      _ = AgentServer.cast(self(), synthetic_child_exit(state, name, :no_proc))
      {:ok, state}
  end
end
```

The synthetic `child.exit` for the no-proc case ensures the state machine doesn't stall waiting for a `:DOWN` that will never come.

### `lib/jido/pod/directive/start_node.ex` *(new file)*

```elixir
defmodule Jido.Pod.Directive.StartNode do
  @moduledoc false

  @schema Zoi.struct(__MODULE__, %{
    name: Zoi.any(description: "Topology node name to start."),
    initial_state: Zoi.map(description: "Override initial state.") |> Zoi.optional(),
    opts: Zoi.map(description: "Runtime opts.") |> Zoi.default(%{})
  }, coerce: true)

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

  def new!(name, opts \\ []) do
    %__MODULE__{name: name, initial_state: Keyword.get(opts, :initial_state), opts: Map.new(Keyword.delete(opts, :initial_state))}
  end
end
```

### `lib/jido/pod/directive/stop_node.ex` *(new file)*

```elixir
defmodule Jido.Pod.Directive.StopNode do
  @moduledoc false

  @schema Zoi.struct(__MODULE__, %{
    name: Zoi.any(description: "Topology node name to stop."),
    reason: Zoi.any(description: "Stop reason.") |> Zoi.default(:shutdown)
  }, coerce: true)

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

  def new!(name, opts \\ []) do
    %__MODULE__{name: name, reason: Keyword.get(opts, :reason, :shutdown)}
  end
end
```

### `lib/jido/pod/directive_exec.ex`

**Delete** the `ApplyMutation` impl (the existing 9-line file) — the directive itself is deleted (next file).

**Add** impls for `StartNode` and `StopNode`:

```elixir
defimpl Jido.AgentServer.DirectiveExec, for: Jido.Pod.Directive.StartNode do
  alias Jido.Pod.Runtime

  def exec(%{name: name, initial_state: initial, opts: opts}, _input_signal, state) do
    case Runtime.start_node(state, name, Map.to_list(opts) ++ List.wrap(initial && {:initial_state, initial})) do
      {:ok, next_state, _pid} -> {:ok, next_state}
      {:ok, next_state} -> {:ok, next_state}
      {:error, next_state, reason} -> {:ok, mark_node_failure(next_state, name, reason)}
    end
  end

  defp mark_node_failure(state, name, reason) do
    # Emit a synthetic child.exit so the state machine treats the failed start as a wave failure.
    signal =
      Jido.Signal.new!(
        "jido.agent.child.exit",
        %{tag: name, pid: nil, reason: {:start_failed, reason}},
        source: "/agent/#{state.id}"
      )

    _ = Jido.AgentServer.cast(self(), signal)
    state
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Pod.Directive.StopNode do
  alias Jido.Pod.Runtime

  def exec(%{name: name, reason: reason}, _input_signal, state) do
    case Runtime.stop_node(state, name, reason) do
      {:ok, next_state} -> {:ok, next_state}
      {:error, next_state, _reason} -> {:ok, next_state}
    end
  end
end
```

### `lib/jido/pod/directive/apply_mutation.ex`

**Delete the file.** No longer needed.

### `lib/jido/pod/mutable.ex`

`mutation_effects/3` (the function called by `Pod.Actions.Mutate.run/4`) returns the list of effects:

- StateOps to set `mutation.id`, `:status` to `:running`, `:plan`, `:phase`, `:awaiting`
- Plus the first wave's StartNode/StopNode directives

```elixir
def mutation_effects(%Agent{} = agent, ops, opts) do
  with {:ok, pod_state} <- TopologyState.fetch_state(agent),
       :ok <- ensure_mutation_idle(pod_state),
       {:ok, topology} <- TopologyState.fetch_topology(agent),
       mutation_id <- Keyword.get(opts, :mutation_id) || generate_mutation_id(),
       {:ok, plan} <- Planner.plan(topology, ops, mutation_id: mutation_id) do
    {first_phase, awaiting, wave_directives} = first_wave(plan)

    mutation_state = %{
      id: plan.mutation_id,
      status: :running,
      plan: plan,
      phase: first_phase,
      awaiting: awaiting,
      report: plan.report,
      error: nil
    }

    {:ok,
     [
       StateOp.set_path([@pod_state_key, :topology], plan.final_topology),
       StateOp.set_path([@pod_state_key, :topology_version], plan.final_topology.version),
       StateOp.set_path([@pod_state_key, :mutation], mutation_state)
       | wave_directives
     ]}
  end
end

# `first_wave/1` decides whether to start with a stop wave or a start wave (stops first if any),
# returns `{phase, awaiting_set, [directives]}`.
defp first_wave(%Plan{stop_waves: [first_stop | _]} = plan) do
  awaiting = %{kind: :exit, names: MapSet.new(first_stop)}
  directives = Enum.map(first_stop, &Jido.Pod.Directive.StopNode.new!/1)
  {{:stop_wave, 0}, awaiting, directives}
end

defp first_wave(%Plan{stop_waves: [], start_waves: [first_start | _]} = plan) do
  awaiting = %{kind: :started, names: MapSet.new(first_start)}
  directives = Enum.map(first_start, &Jido.Pod.Directive.StartNode.new!/1)
  {{:start_wave, 0}, awaiting, directives}
end

defp first_wave(%Plan{stop_waves: [], start_waves: []}) do
  # Empty mutation — phase goes straight to :complete.
  {:complete, nil, []}
end
```

### `lib/jido/pod/actions/mutate_progress.ex` *(new file)*

The state-machine progression action. Routed from `jido.agent.child.started` and `jido.agent.child.exit`. Reads the current mutation slice, removes the named child from `awaiting.names`, and either:

- Awaiting still non-empty → no-op (return current slice unchanged).
- Awaiting empty → advance phase: emit the next wave's directives, OR finalize the mutation by emitting the lifecycle signal.

```elixir
defmodule Jido.Pod.Actions.MutateProgress do
  @moduledoc false

  alias Jido.Pod.Plugin
  alias Jido.Pod.Mutation.Plan
  alias Jido.AgentServer.StateOp
  alias Jido.Agent.Directive.Emit

  use Jido.Action,
    name: "pod_mutate_progress",
    schema: []

  @pod_state_key Plugin.path()

  def run(%Jido.Signal{type: type, data: data}, slice, _opts, _ctx) do
    kind = lifecycle_kind(type)
    name = data.tag

    case slice.mutation do
      %{status: :running, awaiting: %{kind: ^kind, names: names}} = mutation ->
        new_names = MapSet.delete(names, name)
        cond do
          MapSet.size(new_names) > 0 ->
            updated = put_in(mutation.awaiting.names, new_names)
            {:ok, %{slice | mutation: updated}}

          true ->
            advance(slice, mutation)
        end

      _ ->
        # Not part of an in-flight mutation; ignore.
        {:ok, slice}
    end
  end

  defp lifecycle_kind("jido.agent.child.exit"), do: :exit
  defp lifecycle_kind("jido.agent.child.started"), do: :started

  defp advance(slice, %{phase: phase, plan: %Plan{} = plan} = mutation) do
    case next_phase(phase, plan) do
      {next_phase, awaiting, directives} ->
        updated = %{mutation | phase: next_phase, awaiting: awaiting}
        {:ok, %{slice | mutation: updated}, directives}

      :done ->
        complete(slice, mutation, :completed)

      {:error, _reason} ->
        complete(slice, mutation, :failed)
    end
  end

  defp next_phase({:stop_wave, n}, %Plan{stop_waves: stops} = plan) do
    case Enum.at(stops, n + 1) do
      nil ->
        case plan.start_waves do
          [first_start | _] ->
            {{:start_wave, 0}, %{kind: :started, names: MapSet.new(first_start)},
             Enum.map(first_start, &Jido.Pod.Directive.StartNode.new!/1)}

          [] ->
            :done
        end

      next_wave ->
        {{:stop_wave, n + 1}, %{kind: :exit, names: MapSet.new(next_wave)},
         Enum.map(next_wave, &Jido.Pod.Directive.StopNode.new!/1)}
    end
  end

  defp next_phase({:start_wave, n}, %Plan{start_waves: starts}) do
    case Enum.at(starts, n + 1) do
      nil ->
        :done

      next_wave ->
        {{:start_wave, n + 1}, %{kind: :started, names: MapSet.new(next_wave)},
         Enum.map(next_wave, &Jido.Pod.Directive.StartNode.new!/1)}
    end
  end

  defp complete(slice, mutation, status) do
    final_mutation = %{mutation | status: status, phase: :complete, awaiting: nil}

    lifecycle_signal =
      Jido.Signal.new!(
        "jido.pod.mutate.#{status}",
        %{
          mutation_id: mutation.id,
          report: mutation.report,
          error: if(status == :failed, do: mutation.error, else: nil)
        },
        source: "/pod"
      )

    {:ok,
     %{slice | mutation: final_mutation},
     [%Emit{signal: lifecycle_signal}]}
  end
end
```

The lifecycle-signal `Emit` directive flows through the same agent's mailbox; subscribers attached to `jido.pod.mutate.completed` / `.failed` see it after the outermost middleware unwinds.

### `lib/jido/pod/plugin.ex`

Update `signal_routes` to include the lifecycle hooks:

```elixir
signal_routes: [
  {"mutate", MutateAction},
  {"jido.pod.query.nodes", QueryNodes},
  {"jido.pod.query.topology", QueryTopology},
  {"jido.agent.child.started", MutateProgress},
  {"jido.agent.child.exit", MutateProgress}
]
```

Update the slice schema to include `:plan`, `:phase`, `:awaiting`:

```elixir
mutation: Zoi.object(%{
  id: Zoi.string(...) |> Zoi.optional(),
  status: Zoi.atom(...) |> Zoi.default(:idle),
  plan: Zoi.any(...) |> Zoi.optional(),
  phase: Zoi.any(...) |> Zoi.default(:idle),
  awaiting: Zoi.any(...) |> Zoi.optional(),
  report: Zoi.any(...) |> Zoi.optional(),
  error: Zoi.any(...) |> Zoi.optional()
}) |> Zoi.default(%{id: nil, status: :idle, plan: nil, phase: :idle, awaiting: nil, report: nil, error: nil})
```

`build_state/2` updates the default mutation map similarly.

### `lib/jido/pod/actions/mutate.ex`

Already updated in [task 0009](0009-pod-mutate-cast-await-api.md) to use `signal.id` as mutation_id. No further changes — `mutation_effects/3` now returns StartNode/StopNode directives instead of the deleted ApplyMutation, but the action itself doesn't see directive types.

### Tests

- `test/jido/pod/mutation_runtime_test.exs` — the most affected. After this task, mutations no longer block. Test invariants stay: "after `mutate_and_wait`, the requested nodes are running / removed / report has the expected shape." But timing-sensitive tests may need adjustment because the mutation is genuinely concurrent with caller observation. Use `Pod.mutate_and_wait` for the standard "do mutation, assert end state" pattern.

- Add a test: **mailbox stays responsive during a long-stop mutation**. Spawn a pod with a child that has a slow `terminate/2` (e.g. `Process.sleep(2_000)` in the child). Cast a `pod.mutate` to remove that child. Immediately query `Pod.nodes/1`. The query must return *before* the stop completes (within milliseconds). This verifies the unblocked mailbox.

- Add a test: **concurrent mutation rejected with `:mutation_in_progress`**. Cast mutation A (long-running). Immediately call `Pod.mutate(...)` for mutation B. Assert `{:error, :mutation_in_progress}`.

- Add a test: **mutation failure path emits `jido.pod.mutate.failed`**. Use a topology where one node fails to boot. `Pod.mutate_and_wait` returns `{:error, error_report}`.

## Files to create

- `lib/jido/pod/directive/start_node.ex`
- `lib/jido/pod/directive/stop_node.ex`
- `lib/jido/pod/actions/mutate_progress.ex`

## Files to delete

- `lib/jido/pod/directive/apply_mutation.ex`
- The `defimpl ... for: ApplyMutation` block in `lib/jido/pod/directive_exec.ex`

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix test` — full suite passes.
- `Runtime.execute_mutation_plan/3` is gone. Searching for it returns no results in `lib/`.
- `Pod.mutate_and_wait/3` returns `{:ok, report}` on success and `{:error, error_report}` on failure.
- Mailbox-stays-responsive test (described above) passes.
- Concurrent-rejection test passes.
- Failure-path test passes.
- `lib/jido/pod/runtime.ex` is under 300 lines.

## Out of scope

- **Telemetry overhaul.** The new state machine emits its own start/complete telemetry but doesn't reproduce every `[:jido, :pod, :node, :ensure]` event the old code emitted per-node. Telemetry consumers reading those events will need updating; that's a separate task.

- **Subscription-based reconcile reporting.** `reconcile/2` currently returns `{:ok, report}` synchronously. After the refactor it goes via `mutate_and_wait` so semantics match. If a caller wanted streaming progress, they can `subscribe` to `jido.agent.child.started` directly — outside this task's scope.

- **Backpressure on rapid sequential mutations.** Issuing `mutate` immediately after `mutate_and_wait` returns is fine. Issuing `mutate` 50ms apart with the prior still in-flight returns `:mutation_in_progress`, which is the documented behavior. A queue or coalescing strategy belongs in user code.

- **`Pod.Directive.ApplyMutation` archeological removal.** If any tests reference the type, delete those references. If any external (out-of-tree) callers exist (none known), they break. Per the [tasks NO-LEGACY-ADAPTERS rule](README.md), no shim.

## Risks

- **Adoption + lifecycle signal synthesis.** When `start_node` finds an existing pid (adoption), it must emit a synthetic `jido.agent.child.started` so the state machine progresses. Use `AgentServer.cast(self(), signal)` rather than calling the handler directly — keeps the path uniform with real spawns.

- **Crash before `child.started` fires.** A child can crash during `:post_init` after `start_link` succeeded. The pod sees `:DOWN` translated to `child.exit` *without* a preceding `child.started`. The state machine sees an exit while it's awaiting a start — must treat this as "node startup failed" and propagate it as a mutation failure rather than ignoring it. Detect: `awaiting.kind == :started` AND name in `awaiting.names` AND incoming signal type is `child.exit` → mark mutation `:failed` with `{:start_failed, name, reason}`.

- **Wave failure semantics.** If one node in a stop wave fails (somehow), do we abort the mutation or continue? Match current behavior: continue stop waves, report failures at the end. For start waves, abort on first failure.

- **Synthetic exit for stop-of-no-proc.** When `stop_node` finds no child to stop (already gone), emit a synthetic `child.exit` so the state machine doesn't hang. Reason field: `:already_stopped`. State machine treats this as "node is gone, advance."

- **Replan-on-failure not implemented.** This task does NOT implement compensation or rollback if a start fails mid-mutation. The mutation marks `:failed` and stops emitting further waves. Stopping a previously-started new node to roll back would require new mutation semantics. Defer to a future task.

- **`reconcile_ops/1` reads pod state via `AgentServer.state(server)`** which crosses processes. That's a tradeoff — `reconcile/2` becomes a pure wrapper at the cost of a state read. If callers need a "stay-in-process reconcile from inside an action," expose `Pod.reconcile_effects(agent, opts)` analogous to `mutation_effects/3`.

- **Test rewrite cost.** The 35 pod tests in `test/jido/pod/` were written for synchronous mutation semantics. Each will need a small per-test review. Budget 2-3 hours for the test pass.

- **`teardown_runtime/2` semantics.** Currently called in tests for cleanup. Needs to either: (a) become `Pod.mutate_and_wait(server, [Mutation.remove_node(name) | for name <- topology.nodes])`, or (b) stay as a synchronous cleanup using direct `Process.exit` on each child pid. Option (b) is fine for test cleanup; option (a) is cleaner but slower. Pick (b) for now — note in code that it bypasses the state machine intentionally because cleanup happens at supervisor teardown.
