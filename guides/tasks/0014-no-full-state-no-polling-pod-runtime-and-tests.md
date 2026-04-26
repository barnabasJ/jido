# Task 0014 — No full-state reads, no polling: `Pod.Runtime` projection struct + test sweep

- Implements: [ADR 0021](../adr/0021-no-full-state-no-polling.md)
- Depends on: [task 0013](0013-call-takes-selector-cast-and-await-retires.md) (shipped) — `call/4` and `state/3` selectors land first.
- Blocks: [task 0010](0010-pod-runtime-signal-driven-state-machine.md) — the Pod runtime should be operating on the `View` struct before its signal-driven state machine rewrite, so the rewrite isn't churning two axes at once.
- Leaves tree: **green**

## Goal

Make [ADR 0021](../adr/0021-no-full-state-no-polling.md)'s two principles enforceable by grep:

1. `grep -rn "fn s -> {:ok, s} end" lib/ test/` returns zero hits.
2. `grep -rn "eventually_state" test/` returns zero hits; `test/support/eventually.ex` no longer exports `eventually_state/3`.

Two pieces, in order:

### Piece 1 — `Pod.Runtime` projection struct

Replace the full-`%State{}` snapshot with a typed projection in [lib/jido/pod/runtime.ex](../../lib/jido/pod/runtime.ex). Internal helpers take `View.t()`, not `State.t()`.

### Piece 2 — Test sweep

Delete `eventually_state/3`. Replace every state-polling wait with a subscribe-based wait. Replace every full-state inspection with a targeted selector.

## Files to modify

### `lib/jido/pod/runtime.ex`

**Add a `Pod.Runtime.View` struct** (in this file or a new `lib/jido/pod/runtime/view.ex`):

```elixir
defmodule Jido.Pod.Runtime.View do
  @moduledoc """
  Narrow projection of `%AgentServer.State{}` used by `Pod.Runtime`'s
  internal helpers. Built once at the cross-process boundary; never
  refreshed in-place.
  """

  @enforce_keys [:id, :registry, :partition, :jido, :agent_module, :topology]
  defstruct [:id, :registry, :partition, :jido, :agent_module, :topology]

  @type t :: %__MODULE__{
          id: String.t(),
          registry: module(),
          partition: term() | nil,
          jido: atom(),
          agent_module: module(),
          topology: Jido.Pod.Topology.t()
        }
end
```

**Rewrite `fetch_runtime_state/1`** ([lib/jido/pod/runtime.ex:1155](../../lib/jido/pod/runtime.ex)) to return the view:

```elixir
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
         topology: topology
       }}
    end
  end)
end
```

(Renamed from `fetch_runtime_state/1` so the new name advertises the projection.)

**Update internal helper signatures** to take `View.t()` instead of `State.t()`:

- `resolve_runtime_server(server, view)` — reads `view.id`, `view.registry`, `view.partition`.
- `pod_event_metadata(view, extra \\ %{})` — reads `view.id`, `view.agent_module`, `view.jido`, `view.partition`.
- `node_event_metadata(view, %Node{} = node, name, source, owner)` — same.
- `emit_pod_lifecycle(server_pid, view, type, data)` — reads `view.id`.
- `build_node_snapshots(view, topology)` and its callees — reads `view.jido`, `view.partition` for `Jido.parent_binding/3` lookups.
- `execute_runtime_plan(server_pid, view, topology, requested_names, waves, opts)` — propagate the view.
- `execute_runtime_plan_locally(state, ...)` — this branch operates on a *live* `%State{}` (it's the in-handler local-state path used by `execute_mutation_plan/3`), not on a cross-process snapshot. Leave its signature on `State.t()` and document why. The view is for cross-process callers; in-handler code has the real state by definition.
- `execute_stop_waves(root_server_pid, state, ...)` — splits similarly: cross-process callers pass `View.t()`; in-handler callers pass `State.t()`. Two clauses or a normalization at the entry boundary.
- Stop-wave helpers (`stop_planned_node`, `resolve_stop_parent_pid`, etc.) — same split.
- `pod_ancestry(opts, view_or_state)` — reads `agent_module`; both view and state have that field, so a small accessor or two-clause function works.

**Public entry points** that call `fetch_runtime_view/1`:

- `ensure_node/3`
- `reconcile/2`
- `teardown_runtime/2`

After construction, the view is immutable. No helper should reach back into the AgentServer for fields it could have asked for at view construction time.

**Drop the `state.agent` snapshot.** `TopologyState.fetch_topology/1` is the only caller that reads `state.agent` from the snapshot. The new selector calls it inside the selector closure (so it runs on the live state inside the agent process) and stores the resulting topology in the view. The view never carries `:agent` — it carries the projected `:topology` instead. This is the most important shape decision in this task.

**Audit `lib/jido/pod/runtime.ex` for any other `state.agent` reads** that come from a snapshot rather than a live in-handler `%State{}`. Those are bugs (stale-snapshot reads) and should be migrated to either (a) view fields if the data is invariant for the operation, or (b) a fresh selector call if the data must be live.

### `lib/jido/pod/runtime/view.ex` (new file, optional)

If the view definition lives in its own file, alias it from `Pod.Runtime`. Single-file is also fine — the struct is small and tightly coupled to the runtime.

### `test/support/eventually.ex`

**Delete `eventually_state/3`.** Keep `eventually/2`, `assert_eventually/2`, `refute_eventually/2` — those are for non-state waits (external systems, process death, etc.) and remain valid.

Update the moduledoc to remove the `eventually_state` example and note the constraint per ADR 0021:

```elixir
@moduledoc """
Polling-based assertions for non-state waits.

For agent state changes, **subscribe** via `Jido.AgentServer.subscribe/4`
or use one of the `await_*` helpers (`await_ready/2`, `await_child/3`,
`Pod.mutate_and_wait/3`). Polling agent state is forbidden by ADR 0021 —
it hides race conditions and masks the signal that should be driving
the wait.

`eventually/2` survives for genuinely external waits: HTTP endpoints,
external schedulers, processes outside the Jido tree.
"""
```

### `test/support/scheduler_integration_harness.ex`

**Drop the `state(pid)` helper** — it returns the full `%State{}`. Any caller currently using it should switch to a targeted selector at the call site. `tick_count(pid)` and `ticks(pid)` should each become a single targeted `state/3` call:

```elixir
def tick_count(pid) do
  {:ok, count} =
    AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.tick_count} end)

  count
end

def ticks(pid) do
  {:ok, ticks} =
    AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.ticks} end)

  ticks
end
```

`wait_for_job/3` polls `state.cron_jobs[job_id]` — that's a runtime-state poll, not a domain-state poll. Decide whether to keep it as a narrowed `eventually` (cron-job lifecycle has no signal channel today) or to add a `jido.agent.cron.registered` signal so the wait can subscribe. Adding the signal is the better answer; falling back to a narrow `eventually` is acceptable for this task with a comment explaining why no signal exists.

`wait_for_tick_count/3` uses `eventually_state` — replace with a subscribe to whatever signal the domain emits when the tick count advances. If no such signal exists today, this is the framework-coverage gap ADR 0021 calls out: add the signal.

### Test callsites — full-state extractions (~125 hits)

`grep -rn "fn s -> {:ok, s} end" test/` returns the full list. For each:

- Find the lines after the `{:ok, state} = AgentServer.state(pid, ...)` that read `state.foo.bar`.
- Replace with a targeted selector returning just `s.foo.bar`.
- Update the destructure and assertion.

Mechanical recipe:

```elixir
# Before
{:ok, state} = AgentServer.state(pid, fn s -> {:ok, s} end)
assert state.agent.state.domain.counter == 5

# After
{:ok, counter} =
  AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)
assert counter == 5
```

For tests that read multiple fields from the same snapshot:

```elixir
# Before
{:ok, state} = AgentServer.state(pid, fn s -> {:ok, s} end)
assert state.agent.state.domain.counter == 5
assert state.status == :idle

# After
{:ok, %{counter: counter, status: status}} =
  AgentServer.state(pid, fn s ->
    {:ok, %{counter: s.agent.state.domain.counter, status: s.status}}
  end)
assert counter == 5
assert status == :idle
```

Don't reach for `fn s -> {:ok, s} end`. That's the smell ADR 0021 outlaws.

### Test callsites — `eventually_state` waits

`grep -rn "eventually_state" test/` returns the full list. For each:

1. **What signal does the predicate's transition correspond to?** Examples:
   - Predicate `& &1.status == :idle` → `jido.agent.lifecycle.ready` (use `await_ready/2`).
   - Predicate `& &1.agent.state.app.value == 7` after a write → `subscribe/4` to the write signal with a selector that returns the value when it matches.
   - Predicate `& length(&1.children) == 3` after spawn directives → `subscribe/4` to `jido.agent.child.started` and count.
   - Predicate `& &1.agent.state.domain.tick_count >= N` → either `subscribe/4` to whatever tick signal exists, or add one.

2. **Replace the `eventually_state` call with the subscription.** For most "wait for the next event" patterns the right shape is:

   ```elixir
   {:ok, ref} =
     AgentServer.subscribe(pid, "some.signal.pattern", fn s ->
       case <predicate over s> do
         match -> {:ok, <projection>}
         _ -> :skip
       end
     end, once: true)

   assert_receive {:jido_subscription, ^ref, %{result: {:ok, value}}}, timeout
   ```

3. **If no signal fits and adding one isn't justified for this task,** narrow to `eventually/2` (not `eventually_state/3` — that helper is gone) with a tailored selector that returns just the field the predicate touches. Add a comment explaining why subscription wasn't possible. This should be rare.

4. **If the test was waiting for a transition the framework doesn't emit a signal for**, that's a real coverage gap. Either:
   - Add the signal in this task and migrate the test to subscribe to it.
   - File a follow-up to add the signal and gate the test migration on that follow-up.

   Don't paper over the gap with polling.

## Files to create

- `guides/tasks/0014-no-full-state-no-polling-pod-runtime-and-tests.md` (this file)
- Optionally `lib/jido/pod/runtime/view.ex` if the View struct lives in its own module.

## Files to delete

- The `eventually_state/3` and `defp check_state/2` definitions in `test/support/eventually.ex`.
- The `state(pid)` helper in `test/support/scheduler_integration_harness.ex`.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix test` — full suite passes (1854 tests at start; expect ~similar count, possibly more if new signals were added with their own tests).
- `mix credo --strict` — no new warnings vs. main.
- `mix docs` warning count matches main.
- `grep -rn "fn s -> {:ok, s} end" lib/ test/` returns **zero hits**.
- `grep -rn "eventually_state" test/` returns **zero hits**.
- `grep -rn "AgentServer.state" lib/jido/pod/runtime.ex` shows only the single call inside `fetch_runtime_view/1`'s selector (or near-equivalent narrow projections).
- `Pod.Runtime` internal helpers' signatures take `View.t()` (cross-process callers) or `State.t()` (in-handler callers), with the split documented.
- No internal helper accepts both — the boundary is named at the call site.

## Out of scope

- **Adding lifecycle signals for transitions the framework doesn't emit today.** If a test polls because no signal exists, either add the signal in this task (in scope only if it's a one-line emit) or file a follow-up (the test migration gates on the follow-up).
- **Pod runtime signal-driven state-machine rewrite.** That's [task 0010](0010-pod-runtime-signal-driven-state-machine.md). This task changes only how the runtime reads cross-process state; the wave-orchestration logic stays as-is.
- **`AgentServer.subscribe/4` API changes.** It's stable from [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md).
- **Generic `AgentServer.Projection` struct.** Each consumer defines its own view per ADR 0021 §1.

## Risks

- **Subscription registration race.** `subscribe/4` is a synchronous `GenServer.call`, so the subscription is registered before the trigger signal is cast. As long as the test pattern is `subscribe → cast → assert_receive`, there's no race. Pattern bugs (cast before subscribe) will surface as `assert_receive` timeouts — fix the pattern, don't widen the timeout.

- **Tests that depended on polling re-checking after transient failure.** Some `eventually_state` callers used the polling as implicit retry — the predicate was false on the first check but became true after another signal fired. Subscribe-based waits don't retry; they receive the *next* matching event. If a test's correctness depended on coalescing multiple events, it needs to subscribe to the right pattern (potentially with `once: false` and `assert_receive` in a loop until the predicate fires).

- **Splitting helpers across `View` / `State` signatures.** Some Pod runtime helpers serve both cross-process callers (boundary-crossing) and in-handler callers (live state). Two clauses with different signatures is the recommended pattern; alternatively, normalize at the entry boundary so internal helpers always take one type. Pick one approach and apply it consistently.

- **`build_node_snapshots/2` is publicly used.** It's exported because [ADR 0020 §reply_from_state callers](../../lib/jido/signal/call.ex) build replies from `%State{}` via `Reply` directives. Those callers have the live state and should keep passing `%State{}`. Either keep `build_node_snapshots/2` on `State.t()` (and have the cross-process callers extract a tiny adapter) or split it into `build_node_snapshots_from_view/2` and `build_node_snapshots_from_state/2`. Decide based on whether the function actually needs different fields in the two paths.

- **Test sweep size.** ~125 full-state inspection rewrites is mechanical but tedious. Doing the `Pod.Runtime` piece first (smaller, focused) and validating greens before the test sweep keeps the diff reviewable.

- **`eventually_state` users that genuinely need to wait on derived state.** Some predicates compute `length(state.something) >= 3` or similar; the "right" selector is `fn s -> {:ok, length(s.something)} end` and the wait is signal-driven. If the derived state has no triggering signal, that's an architectural gap (per ADR 0021 §2) — surface it in the task PR, don't bury it.

- **`test/support/eventually.ex` is imported by many test files via `import JidoTest.Eventually`.** Removing only `eventually_state/3` and keeping `eventually/2` minimizes blast radius. The deleted function will surface as a compile error in tests that still call it; each one needs migration before the test will compile.
