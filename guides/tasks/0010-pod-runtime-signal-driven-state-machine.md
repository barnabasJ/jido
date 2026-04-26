# Task 0010 — Pod runtime: signal-driven state machine; delete wave orchestration

- Implements: [ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md) Phase 2 — runtime simplification + state machine; enforces [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) (strict separation) on the Pod surface
- Depends on: [task 0009](0009-pod-mutate-cast-await-api.md) (caller API already cast_and_await + lifecycle signal-shaped); [task 0012](0012-delete-state-op-directives.md) (`StateOp` deleted, multi-slice via return shape, `Pod.Actions.Mutate` re-pathed to `:pod`); transitively [task 0011](0011-tagged-tuple-return-shape.md)
- Blocks: nothing — this is the terminal task for ADR 0017
- Leaves tree: **green**

## Goal

Replace `Jido.Pod.Runtime`'s wave-orchestrating machinery (~1100 lines) with a signal-driven state machine. Mutations decompose into a stream of fast directive applications coordinated by the natural `jido.agent.child.started` and `jido.agent.child.exit` signals the runtime already emits. The pod's mailbox is never blocked by mutation work.

This task ships under [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md): every new directive (`StartNode`, `StopNode`) is a **pure side effect** that touches `state.children` (runtime) but **never** `state.agent.state` (domain). All `agent.state.pod.mutation` field updates happen in **action handlers** wired to `signal_routes` for `jido.agent.child.started` / `jido.agent.child.exit`. Without that rule, the natural temptation is to fold the slice update into the directive body — re-collapsing into the compound `ApplyMutation` shape this task was meant to escape.

**No synthetic completion signal.** Earlier drafts of [ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md) had `MutateProgress.complete/3` emit a `jido.pod.mutate.{completed,failed}` lifecycle signal at the tail. That's removed. The slice transition to terminal status is the contract subscribers read; emitting a synthetic notification would re-broadcast state already in the slice, violating ADR 0019's "single source of truth" principle. Callers who want to wait for a mutation use `Pod.mutate_and_wait/3` or `Pod.subscribe_mutation/3`, both of which internally subscribe to the natural `jido.agent.child.*` signals with a selector that reads `pod.mutation`.

After this task:

- `Runtime` shrinks from ~1400 lines to ~250 — only read-side helpers (`nodes/1`, `lookup_node/2`, `build_node_snapshots/2`) and two new primitives (`start_node/2`, `stop_node/2`).
- `ApplyMutation` directive is deleted. Its work splits cleanly per ADR 0019: `StartNode` / `StopNode` directives do the I/O; the `MutateProgress` action wired into `signal_routes` does the slice updates.
- `Pod.Actions.Mutate.run/4` (already re-pathed to `:pod` by task 0012) plans the mutation, returns the new pod slice with `mutation: %{phase: ..., awaiting: ..., ...}` directly, and emits the first wave of `StartNode`/`StopNode` directives. No `StateOp` writes — the slice value carries it all.
- The pod plugin gets two new signal_routes (`jido.agent.child.started`, `jido.agent.child.exit`) bound to `MutateProgress` which advances the state machine.
- `Pod.mutate_and_wait/3` (shipped in task 0009 subscribing to `jido.pod.mutate.completed/.failed`) is rewritten to subscribe to `jido.agent.child.*` with a selector that reads `pod.mutation` and matches by `mutation.id`.
- New `Pod.subscribe_mutation/3` public helper for the per-mutation subscription pattern.

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

`mutation_effects/3` (the function called by `Pod.Actions.Mutate.run/4` after task 0012's re-path to `path: :pod`) now returns **the new pod slice value plus side-effect directives** — no `StateOp` directives, per [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md).

```elixir
@spec mutation_effects(Agent.t(), [Mutation.t() | term()], keyword()) ::
        {:ok, pod_slice :: map(), [side_effect_directive]} | {:error, term()}
def mutation_effects(%Agent{} = agent, ops, opts) do
  with {:ok, pod_slice} <- TopologyState.fetch_state(agent),
       :ok <- ensure_mutation_idle(pod_slice),
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

    new_pod_slice = %{pod_slice |
      topology: plan.final_topology,
      topology_version: plan.final_topology.version,
      mutation: mutation_state
    }

    {:ok, new_pod_slice, wave_directives}
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

`Pod.Actions.Mutate.run/4` (re-pathed to `:pod` in task 0012) becomes:

```elixir
def run(%Jido.Signal{id: signal_id, data: %{ops: ops, opts: opts}}, _slice, _opts, ctx) do
  effect_opts = Keyword.put(Map.to_list(opts || %{}), :mutation_id, signal_id)
  Pod.mutation_effects(ctx.agent, ops, effect_opts)
end
```

Three-tuple return passed straight through — `mutation_effects` already returns `{:ok, new_pod_slice, wave_directives}`.

### `lib/jido/pod/actions/mutate_progress.ex` *(new file)*

The state-machine progression action — declared with `path: :pod` (it owns the slice it mutates per [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md)). Routed from `jido.agent.child.started` and `jido.agent.child.exit`. Reads the current mutation slice and on each signal:

1. **Classifies the event** relative to the current phase and updates `mutation.report` incrementally with whatever the signal payload tells it (which name started, which exited, with what reason).
2. **Removes the name from `awaiting.names`**.
3. **Advances if awaiting empty** — emit the next wave's directives and transition phase, OR finalize the mutation (status, terminal report) and emit the lifecycle signal.

The report build-up is the load-bearing part. Signal payloads carry the per-node outcome (`tag`, `pid`, `reason` from the AgentServer's child lifecycle emissions); `MutateProgress` accumulates these into `mutation.report.started`, `report.stopped`, `report.failures` so that by the time `status` flips to `:completed`/`:failed`, the slice already shows the full report. The lifecycle signal cast at the tail of `complete/3` is post-hoc notification — subscribers and `mutate_and_wait` callers read the report from the slice, not from the signal payload.

This is the canonical example of ADR 0019: the directive (`StartNode`/`StopNode`) does I/O and produces a lifecycle signal carrying the result; the action (`MutateProgress`) sees the signal, builds the report incrementally, and produces the slice change. No state mutation in the directive body, no I/O in the action body.

**Event classification table** (drives `update_report/4`):

| Phase | Signal | Outcome | Report update |
|---|---|---|---|
| `{:stop_wave, n}` | `child.exit{tag, _reason}` for `tag ∈ awaiting.names` | expected stop | `report.stopped += [tag]` |
| `{:start_wave, n}` | `child.started{tag, pid}` for `tag ∈ awaiting.names` | expected start | `report.started += [tag]`; `report.nodes[tag] = %{pid: pid, source: :started, ...}` |
| `{:start_wave, n}` | `child.exit{tag, reason}` for `tag ∈ awaiting.names` | startup failure (boot crashed before `:post_init` fired `child.started`) | `report.failures[tag] = reason`; abort wave |
| any | signal for `tag ∉ awaiting.names` | unrelated | no-op |

```elixir
defmodule Jido.Pod.Actions.MutateProgress do
  @moduledoc false

  alias Jido.Pod.Mutation.Plan

  use Jido.Action,
    name: "pod_mutate_progress",
    path: :pod,
    schema: []

  def run(%Jido.Signal{type: type, data: data}, slice, _opts, _ctx) do
    kind = lifecycle_kind(type)
    name = data.tag

    case slice.mutation do
      %{status: :running, awaiting: %{kind: awaiting_kind, names: names}} = mutation
        when awaiting_kind == kind ->
        if MapSet.member?(names, name) do
          updated_report = update_report(mutation.report, mutation.phase, type, data)
          new_names = MapSet.delete(names, name)

          mutation =
            mutation
            |> Map.put(:report, updated_report)
            |> put_in([Access.key!(:awaiting), :names], new_names)

          cond do
            MapSet.size(new_names) > 0 ->
              {:ok, %{slice | mutation: mutation}, []}

            startup_failures?(mutation) ->
              # Abort early: any failure in a start wave finalizes as :failed
              # without emitting further waves. Stop-wave failures are rare
              # (Process.exit can't fail observably) but if surfaced via
              # signal payload, treated the same.
              complete(slice, mutation, :failed)

            true ->
              advance(slice, mutation)
          end
        else
          # Signal for a name we're not awaiting — unrelated to this mutation.
          {:ok, slice, []}
        end

      _ ->
        # Not part of an in-flight mutation; ignore.
        {:ok, slice, []}
    end
  end

  defp lifecycle_kind("jido.agent.child.exit"), do: :exit
  defp lifecycle_kind("jido.agent.child.started"), do: :started

  # Build up the report from each signal. The signal payload carries `tag`,
  # `pid`, `reason` — exactly what the per-node entry needs.
  defp update_report(report, {:stop_wave, _}, "jido.agent.child.exit", %{tag: tag}) do
    %{report | stopped: append_unique(report.stopped, tag)}
  end

  defp update_report(report, {:start_wave, _}, "jido.agent.child.started", %{tag: tag, pid: pid} = data) do
    %{report |
      started: append_unique(report.started, tag),
      nodes: Map.put(report.nodes, tag, %{pid: pid, source: :started, owner: data[:owner]})
    }
  end

  defp update_report(report, {:start_wave, _}, "jido.agent.child.exit", %{tag: tag, reason: reason}) do
    %{report | failures: Map.put(report.failures, tag, {:start_failed, reason})}
  end

  defp update_report(report, _phase, _type, _data), do: report

  defp startup_failures?(%{report: %{failures: failures}}), do: map_size(failures) > 0

  defp advance(slice, %{phase: phase, plan: %Plan{} = plan} = mutation) do
    case next_phase(phase, plan) do
      {next_phase_value, awaiting, directives} ->
        updated = %{mutation | phase: next_phase_value, awaiting: awaiting}
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
    # Report is already fully built from the per-signal updates above.
    # The terminal slice IS the contract — no Emit, no synthetic
    # completion signal. Subscribers attached to jido.agent.child.* (via
    # Pod.subscribe_mutation/3 or Pod.mutate_and_wait/3) read the terminal
    # report from the slice when they fire on the same child event that
    # triggered this complete/3 call.
    final_mutation = %{mutation |
      status: status,
      phase: :complete,
      awaiting: nil,
      error: if(status == :failed, do: mutation.report, else: nil)
    }

    {:ok, %{slice | mutation: final_mutation}, []}
  end
end
```

No `Emit` directive, no `Jido.Agent.Directive.Emit` alias, no lifecycle signal. The chain of events for a subscriber:

1. Last awaited `child.started` / `child.exit` arrives in the pod's mailbox.
2. `MutateProgress` runs as the routed handler. `complete/3` returns the terminal slice (`status: :completed`/`:failed`, full report).
3. Framework commits the slice update.
4. `fire_post_signal_hooks/3` runs for the child lifecycle signal that triggered this turn.
5. Subscribers matching `jido.agent.child.*` (or the specific signal type) fire. Their selector reads the terminal slice and returns the result.

The state-before-emit invariant from earlier drafts becomes a non-issue: there's nothing to emit. The slice update happens *during* the same handler turn that fires the subscribers, in the same `fire_post_signal_hooks` invocation that comes right after.

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

Already updated in [task 0009](0009-pod-mutate-cast-await-api.md) to use `signal.id` as mutation_id, and re-pathed to `path: :pod` in task 0012. After this task, the action body becomes a one-liner forwarding to `Pod.mutation_effects/3`, which now returns `{:ok, new_pod_slice, [side_effect_directives]}` directly:

```elixir
def run(%Jido.Signal{id: signal_id, data: %{ops: ops, opts: opts}}, _slice, _opts, ctx) do
  effect_opts = Keyword.put(Map.to_list(opts || %{}), :mutation_id, signal_id)
  Pod.mutation_effects(ctx.agent, ops, effect_opts)
end
```

### `lib/jido/pod/mutable.ex` (continued)

`Pod.mutate_and_wait/3` and `Pod.subscribe_mutation/3` get rewritten to subscribe to the natural child lifecycle signals instead of the (now-deleted) `jido.pod.mutate.{completed,failed}` synthetic signals. The public API is unchanged — callers don't see the internal pattern shift.

```elixir
@spec subscribe_mutation(AgentServer.server(), String.t(), keyword()) ::
        {:ok, reference()} | {:error, term()}
def subscribe_mutation(server, mutation_id, opts \\ []) when is_binary(mutation_id) do
  AgentServer.subscribe(
    server,
    "jido.agent.child.*",
    terminal_selector(mutation_id),
    Keyword.put_new(opts, :once, true)
  )
end

@spec mutate_and_wait(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
        {:ok, Pod.mutation_report()} | {:error, term()}
def mutate_and_wait(server, ops, opts \\ []) when is_list(opts) do
  await_timeout =
    Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, :timer.seconds(30)))

  signal =
    Signal.new!("pod.mutate", %{ops: ops, opts: Map.new(opts)}, source: "/jido/pod/mutate")

  expected_id = signal.id

  # Single subscription matching both `jido.agent.child.started` and
  # `jido.agent.child.exit`. The selector returns :skip until MutateProgress
  # flips mutation.status to terminal; once: true unsubscribes on the first
  # non-:skip return.
  with {:ok, sub_ref} <- subscribe_mutation(server, expected_id, once: true) do
    case AgentServer.cast_and_await(server, signal, &default_selector/1, timeout: await_timeout) do
      {:ok, %{queued: true}} ->
        wait_for_terminal(server, sub_ref, await_timeout)

      {:error, _reason} = error ->
        _ = AgentServer.unsubscribe(server, sub_ref)
        error
    end
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
    {:jido_subscription, ^sub_ref, %{result: {:ok, report}}} -> {:ok, report}
    {:jido_subscription, ^sub_ref, %{result: {:error, error}}} -> {:error, error}
  after
    timeout ->
      _ = AgentServer.unsubscribe(server, sub_ref)
      {:error, :timeout}
  end
end
```

The previous Phase-1 `completion_selector/1` and `failure_selector/1` (one each for `.completed` and `.failed`), plus the two-subscription dance in `mutate_and_wait`, collapse into a single `terminal_selector/1` and one subscription. The selector handles both terminal branches because `mutation.status` is the discriminator, not the signal type.

### `lib/jido/pod.ex`

Add a defdelegate for `subscribe_mutation/3`:

```elixir
@doc """
Subscribe to a specific mutation's terminal transition by `mutation_id`
(returned by the queued ack from `Pod.mutate/3`).

Internally subscribes to `jido.agent.child.*` with a selector that matches
by `mutation_id` and reads `pod.mutation.status`. Fires once with the
terminal slice's `report` (on `:completed`) or `error` (on `:failed`),
then auto-unsubscribes (`once: true` by default).

## Returns

- `{:ok, sub_ref}` — subscription registered. Subscriber receives
  `{:jido_subscription, sub_ref, %{result: {:ok, report}}}` on completion
  or `{:jido_subscription, sub_ref, %{result: {:error, error}}}` on
  failure.
- `{:error, reason}` — server lookup or pattern compilation failed.
"""
@spec subscribe_mutation(AgentServer.server(), String.t(), keyword()) ::
        {:ok, reference()} | {:error, term()}
defdelegate subscribe_mutation(server, mutation_id, opts \\ []), to: Mutable
```

### Tests

- `test/jido/pod/mutation_runtime_test.exs` — the most affected. After this task, mutations no longer block. Test invariants stay: "after `mutate_and_wait`, the requested nodes are running / removed / report has the expected shape." But timing-sensitive tests may need adjustment because the mutation is genuinely concurrent with caller observation. Use `Pod.mutate_and_wait` for the standard "do mutation, assert end state" pattern.

- **Delete the `jido.pod.mutate.completed` and `.failed` lifecycle subscriber tests** added in task 0009 (`lifecycle signal jido.pod.mutate.completed reaches subscribers...` and `lifecycle signal jido.pod.mutate.failed reaches subscribers...`). The synthetic completion signal no longer exists. Replacement coverage: see the new "subscribe-to-child-events sees terminal slice" tests below.

- **Delete `StuckMutationAction` shim.** The fixture introduced in task 0009 forged the slice into `:running` to test concurrent rejection. After this task, two `Pod.mutate` casts in quick succession naturally produce one running and one rejected without state forging. The shim and the two tests that use it (`Pod.mutate while mutation slice is :running...` and `Pod.mutate_and_wait propagates the action error directly...`) rewrite as natural concurrent-cast scenarios — see the new `concurrent mutation rejected` test below. Note: this task also depends on task 0012 which deletes `StateOp`, so the shim's `StateOp.set_path` body wouldn't compile anyway — coordinated removal.

- Add a test: **mailbox stays responsive during a long-stop mutation**. Spawn a pod with a child that has a slow `terminate/2` (e.g. `Process.sleep(2_000)` in the child). Cast a `pod.mutate` to remove that child. Immediately query `Pod.nodes/1`. The query must return *before* the stop completes (within milliseconds). This verifies the unblocked mailbox.

- Add a test: **concurrent mutation rejected with `:mutation_in_progress`**. Cast mutation A with a slow-to-stop or slow-to-start node. While A is in-flight (slice is `:running`, awaiting child lifecycle signals), call `Pod.mutate(...)` for mutation B. Assert mutation B returns the wrapped `:mutation_in_progress` error via the framework error channel. This is the natural form of the test that task 0009 had to fake with `StuckMutationAction`.

- Add a test: **mutation failure path produces `{:error, report}`**. Use a topology where one node fails to boot. `Pod.mutate_and_wait` returns `{:error, error_report}`. Assert `error_report.status == :failed` and the failed node appears in `error_report.failures`.

- Add a test: **`Pod.subscribe_mutation/3` fires once with terminal slice**. Cast `Pod.mutate`, take the returned `mutation_id` from the queued ack, call `Pod.subscribe_mutation(pod, mutation_id)`, assert the test process receives `{:jido_subscription, ref, %{result: {:ok, report}}}` with `report.status == :completed`. Verifies the public helper without going through `mutate_and_wait`.

- Add a test: **report build-up — `report.nodes[name].pid` is set after a successful start**. Run a mutation that adds an eager node. After completion, assert `report.nodes[name].pid` is a live pid. This guards the signal-payload contract from finding 4 — if `child.started`'s payload ever stops carrying `pid`, this test breaks loudly rather than silently producing reports without pids.

- Add a test: **strict-separation invariant — `StartNode` does not write `agent.state`**. Capture `state.agent.state` before a single `StartNode` directive applies, apply via direct `DirectiveExec.exec/3` call, capture after. Assert the two values are equal (no slice value changed). The state machine progression's slice update should only happen via the `MutateProgress` action handling the resulting `child.started` signal.

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

- **ADR 0019 enforcement is on the implementer, not the type system.** Nothing prevents `StartNode.exec/3` from sneakily updating `state.agent.state` while it's at it. The bright line is convention + code review. Add the strict-separation test (above) to make accidental violations break loudly. If a future directive author needs to update `agent.state`, the right answer is "emit a signal, write a handler action" — not "while we're in here, also update the slice."

- **`MutateProgress` is the single source of truth for the report.** The directives don't return data to the action that emitted them — `StartNode` spawns and returns; `StopNode` sends `:shutdown` and returns. The result of each operation comes back as a `child.started` / `child.exit` signal whose payload (`tag`, `pid`, `reason`) carries everything `MutateProgress` needs to build `mutation.report` incrementally. If those signal payloads ever change shape (e.g. AgentServer's `notify_parent_of_startup/1` stops including `pid`), the report build-up breaks silently — the test suite needs an explicit assertion that `report.nodes[name].pid` is set after a successful start, not just that `status: :completed`.

- **Selector wakeups for unrelated child traffic.** `Pod.subscribe_mutation/3` and `Pod.mutate_and_wait/3` subscribe to `jido.agent.child.*` — which fires for *every* child lifecycle event in the pod, not just events from the targeted mutation. The selector's `mutation.id` match filters out unrelated events (returns `:skip`), but the selector still runs. For a busy pod with concurrent unrelated child traffic, the cost is one selector evaluation per unrelated event. Selectors are microsecond-fast (map get + match), so this is a real-but-small cost. If it ever shows up in profiles, the fix is to add a more specific subscription pattern that filters by mutation context — but that's premature today.

- **No synthetic completion signal — by design.** Earlier drafts of [ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md) had `MutateProgress.complete/3` emit `jido.pod.mutate.{completed,failed}`. We removed it: subscribing to `jido.agent.child.*` already gives you the same observation, the slice is the source of truth, and emitting a synthetic notification would re-broadcast state already in the slice. If a future implementer feels the urge to "add a completion signal so subscribers don't have to know about child internals," resist — the public-API helpers (`Pod.subscribe_mutation/3`, `Pod.mutate_and_wait/3`) already wrap that. The synthetic signal is a redundant secondary state-mutation channel per [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md).

- **Adoption + lifecycle signal synthesis.** When `start_node` finds an existing pid (adoption), it must emit a synthetic `jido.agent.child.started` so the state machine progresses. Use `AgentServer.cast(self(), signal)` rather than calling the handler directly — keeps the path uniform with real spawns.

- **Crash before `child.started` fires.** A child can crash during `:post_init` after `start_link` succeeded. The pod sees `:DOWN` translated to `child.exit` *without* a preceding `child.started`. The state machine sees an exit while it's awaiting a start — must treat this as "node startup failed" and propagate it as a mutation failure rather than ignoring it. Detect: `awaiting.kind == :started` AND name in `awaiting.names` AND incoming signal type is `child.exit` → mark mutation `:failed` with `{:start_failed, name, reason}`.

- **Wave failure semantics.** If one node in a stop wave fails (somehow), do we abort the mutation or continue? Match current behavior: continue stop waves, report failures at the end. For start waves, abort on first failure.

- **Synthetic exit for stop-of-no-proc.** When `stop_node` finds no child to stop (already gone), emit a synthetic `child.exit` so the state machine doesn't hang. Reason field: `:already_stopped`. State machine treats this as "node is gone, advance."

- **Replan-on-failure not implemented.** This task does NOT implement compensation or rollback if a start fails mid-mutation. The mutation marks `:failed` and stops emitting further waves. Stopping a previously-started new node to roll back would require new mutation semantics. Defer to a future task.

- **`reconcile_ops/1` reads pod state via `AgentServer.state(server)`** which crosses processes. That's a tradeoff — `reconcile/2` becomes a pure wrapper at the cost of a state read. If callers need a "stay-in-process reconcile from inside an action," expose `Pod.reconcile_effects(agent, opts)` analogous to `mutation_effects/3`.

- **Test rewrite cost.** The 35 pod tests in `test/jido/pod/` were written for synchronous mutation semantics. Each will need a small per-test review. Budget 2-3 hours for the test pass.

- **`teardown_runtime/2` semantics.** Currently called in tests for cleanup. Needs to either: (a) become `Pod.mutate_and_wait(server, [Mutation.remove_node(name) | for name <- topology.nodes])`, or (b) stay as a synchronous cleanup using direct `Process.exit` on each child pid. Option (b) is fine for test cleanup; option (a) is cleaner but slower. Pick (b) for now — note in code that it bypasses the state machine intentionally because cleanup happens at supervisor teardown.
