# 0017. Pod mutations are signal-driven; async actions ack-and-lifecycle-signal

- Status: Accepted
- Implementation: Partial — ADR + ETS lock deletion in this commit; Phase 1 (API) tracked by [task 0009](../tasks/0009-pod-mutate-cast-await-api.md); Phase 2 (runtime simplification) tracked by [task 0010](../tasks/0010-pod-runtime-signal-driven-state-machine.md). [Task 0011](../tasks/0011-tagged-tuple-return-shape.md) (ADR 0018) lands before 0009 so the cast_and_await selectors are written in their simplified single-clause form.
- Date: 2026-04-25
- Related commits: (this commit — ADR + ETS lock deletion only)
- Related ADRs: [0014](0014-slice-middleware-plugin.md), [0015](0015-agent-start-is-signal-driven.md), [0016](0016-agent-server-ack-and-subscribe.md)

## Context

`Jido.Pod.Runtime` (1400+ lines) implements pod mutations as a synchronous wave orchestrator: `execute_mutation_plan/3` loops through stop waves and start waves, calling `await_process_exit` (30s default) between waves and using `Task.async_stream` for intra-wave parallelism. Because `ApplyMutation`'s `DirectiveExec.exec/3` runs inline in the AgentServer's signal pipeline, the entire orchestration blocks the pod's mailbox. A pod with five children being torn down can park its mailbox for ten-plus seconds; queries, reads, telemetry, and a *second* `pod.mutate` all wait.

The blocking shape was hidden by an ETS lock layered over the orchestration to short-circuit a concurrent `pod.mutate`, but that layer was a workaround for a problem we shouldn't have: the mailbox itself serializes per-process FIFO. The ETS lock was deleted in the prior commit on this branch; what remains is the deeper question of why the work blocks the mailbox at all.

Starting and stopping individual agents is *cheap*. A start is `DynamicSupervisor.start_child` (microseconds for the spawn — the child's own `:post_init` runs after). A stop is `Process.exit(pid, :shutdown)` followed by waiting for `:DOWN`. The wait is the only expensive part, and the `:DOWN` already arrives as a process message that the AgentServer translates into a `jido.agent.child.exit` signal. We've been *waiting in line* for an event the runtime is already going to deliver.

[ADR 0016](0016-agent-server-ack-and-subscribe.md) shipped `cast_and_await/4` and `subscribe/4` but did not prescribe *when* an action author should use which. The `Pod.mutate/3` selector polled `mutation.status` from agent state — a pattern that conflates "did my call succeed" with "is the in-flight work done." The two are different observations and want different primitives.

## Decision

### 1. Pod mutations run as a signal-driven state machine

Mutations stop being a single blocking function. They become a sequence of small directive applications coordinated by lifecycle signals:

```
pod.mutate (incoming)
   ↓
   action: ensure_idle, plan, set mutation slice, kick off first wave
   action returns; mailbox FREE
   ↓
   first wave: emit StopNode/StartNode directives for each node (cheap, sync)
   ↓
   ... waits ...
   ↓
jido.agent.child.exit / jido.agent.child.started signals arrive (one per node)
   ↓
   pod-plugin handler: decrement awaiting set; if empty, advance phase
   ↓
   advance: kick off next wave OR emit jido.pod.mutate.completed/failed
```

The pod's `mutation` slice grows two fields:

```elixir
mutation = %{
  id: id,
  status: :idle | :running | :completed | :failed,
  plan: %{stop_waves: [...], start_waves: [...]},
  phase: :idle | {:stop_wave, n} | {:start_wave, n} | :complete,
  awaiting: %{kind: :exit | :started, names: MapSet.t()},
  report: report | nil,
  error: any | nil,
}
```

Two new directives:

- `Jido.Pod.Directive.StartNode{name: name}` — `DirectiveExec.exec/3` resolves the topology entry, calls `InstanceManager` to spawn the child. Returns `{:ok, state}` immediately. No wait — the resulting `jido.agent.child.started` signal advances the state machine.
- `Jido.Pod.Directive.StopNode{name: name, reason: term}` — `DirectiveExec.exec/3` looks up the child pid in `state.children`, sends `:shutdown`. Returns `{:ok, state}` immediately. No wait — the resulting `jido.agent.child.exit` signal advances the state machine.

The pod plugin extends its `signal_routes` with two handlers that advance the state machine on `jido.agent.child.started` and `jido.agent.child.exit` (both already emitted by AgentServer per [ADR 0001](0001-children-boot-with-parent-ref.md) and `handle_child_down/3`). The handlers check whether the named node is in `mutation.awaiting.names`; if removing it empties the set, they advance the phase by emitting StartNode/StopNode directives for the next wave or — at the end — emitting the lifecycle signal.

`Jido.Pod.Directive.ApplyMutation` is deleted. `Jido.Pod.Runtime.execute_mutation_plan/3`, `execute_runtime_plan/6`, `execute_runtime_plan_locally/5`, `execute_stop_waves/8`, `await_process_exit`, and the wave-orchestration helpers are deleted along with it. What remains in `Runtime`: the read-side helpers (`nodes/1`, `lookup_node/2`, `build_node_snapshots/2`), `start_node/2` / `stop_node/2` primitives, and small directive bodies. `Runtime` shrinks from ~1400 lines to ~250.

### 2. Async actions follow ack-and-lifecycle-signal

For any action whose work *cannot complete inside one mailbox turn*, the pattern is:

**Action handler does only fast work**: validate, plan, set a `:running`-style marker in slice state, return directives to start the work. The action's return crosses back to the caller via `cast_and_await/4`'s ack, immediately, carrying a *correlation id* (typically `signal.id`).

**Async work emits a lifecycle signal on completion**: `<domain>.<verb>.{completed,failed}` carrying the correlation id and the terminal payload (report/error). For pods this is `jido.pod.mutate.completed` / `jido.pod.mutate.failed`.

**Callers who need to wait subscribe before they cast**:

```elixir
mutation_id = signal.id  # known before the cast

{:ok, sub_ref} = AgentServer.subscribe(server, "jido.pod.mutate.completed",
  fn s ->
    case get_in(s.agent.state, [:pod, :mutation]) do
      %{id: ^mutation_id, status: :completed, report: r} -> {:ok, r}
      %{id: ^mutation_id, status: :failed, error: e} -> {:error, e}
      _ -> :skip
    end
  end,
  once: true
)

{:ok, %{queued: true}} = AgentServer.cast_and_await(server, signal, &queued_selector/1)

receive do
  {:jido_subscription, ^sub_ref, %{value: result}} -> result
end
```

Subscribing **before** casting is what makes this race-free: the subscription is registered before the trigger signal enters the mailbox, so the lifecycle signal can't fire in a gap. The ADR 0016 hook point — selector runs after the outermost middleware unwinds — guarantees that by the time the lifecycle signal's selector fires, the slice has been updated.

A thin convenience wrapper, `Pod.mutate_and_wait/3`, encapsulates subscribe-then-cast-then-receive for callers that don't want to thread the dance manually.

### 3. Concurrent-mutate rejection rides the cast_and_await ack

When a second `pod.mutate` arrives while `mutation.status == :running`, the action's `ensure_mutation_idle/1` returns `{:error, :mutation_in_progress}` before any directives are emitted. Per [ADR 0016](0016-agent-server-ack-and-subscribe.md): "On unexpected error during `on_signal` or directive execution, the selector is not invoked; the caller receives `{:jido_ack, ref, {:error, reason}}`." The second caller's `cast_and_await` returns `{:error, :mutation_in_progress}` directly. No deleted ETS lock, no parallel rejection mechanism. This is the entire reject-on-busy story.

## Consequences

**Mailbox is never blocked by mutation work.** Each individual event (one StartNode directive, one StopNode directive, one child-lifecycle handler) does microsecond-fast work and returns. Stop waits (the previously-blocking part) are absorbed by the natural `:DOWN → child.exit signal` translation that already exists. A pod with 50 children to tear down processes 50 quick events, not one 50-second event.

**Within-wave parallelism happens for free.** When the action emits N StopNode directives for a wave, the directive applications are sequential but each just sends `:shutdown`. The N children exit in parallel because they're separate processes; their `:DOWN`s arrive in whatever order, get translated to N `child.exit` signals, and the pod handles them as they come. No `Task.async_stream` needed — concurrency is in the actor model.

**Inter-wave ordering is enforced by the awaiting set.** The state machine doesn't advance until `awaiting.names` is empty. If a wave has [a, b, c], all three must arrive before the next wave kicks off. This matches the previous semantics.

**Reconcile and `ensure_node` collapse onto the same primitives.** They become trivial wrappers: `ensure_node(pod, name)` is "submit a one-node-add mutation"; `reconcile(pod, opts)` is "submit a mutation that adds all eager-not-yet-running nodes." Their multi-hundred-line implementations in the old `Runtime` evaporate.

**Adoption stays as a single branch in `start_node`.** If `state.children[name]` already has a live pid, `start_node` returns immediately (no spawn) and emits a synthetic `jido.agent.child.started` so the state machine sees a uniform "node is up" event regardless of source.

**Public API change.** `Pod.mutate/3` returns `{:ok, %{mutation_id: id, queued: true}}` immediately, not `{:ok, report}`. Callers that want the report use `Pod.mutate_and_wait/3`. Per the [tasks NO-LEGACY-ADAPTERS rule](../tasks/README.md), no compatibility shim. Tests assert on the new shape.

**Tests rewritten, not deleted.** The mutation-runtime tests previously asserted on synchronous reports from `Pod.mutate/3`. They now assert via `Pod.mutate_and_wait/3` or by directly subscribing to the lifecycle signal. Functional coverage is preserved; the tests just match the new API.

**Telemetry simplified.** `observe_pod_operation` wrapping was per-node and per-wave in the old code; now it lives at the mutation envelope (start, complete) and per-directive (StartNode start, StopNode start). Detailed wave timing is observable via the lifecycle signals themselves — emit timestamps on each phase transition.

**Crash recovery is now a first-class flow, not a fragile retry loop.** If a child fails to start (its boot crashes before `child.started` fires), the pod sees a `:DOWN` for that pid before any `child.started`. The mutation handler treats unrecognized `:DOWN`s during a start wave as a wave failure, marks the mutation `:failed`, and emits `jido.pod.mutate.failed` with details. The previous code raced against the start timeout.

**ADR 0016's selector-on-state usage for waiting on long-running work is deprecated.** It still works for short-running pipelines (the trigger signal completes inside one mailbox turn), but for anything that crosses the mailbox boundary multiple times, the prescribed pattern is subscribe-to-lifecycle-signal. This is now documented prescriptively.

## Alternatives considered

**Spawn `execute_mutation_plan` in a `Task.Supervisor`-backed task.** Smallest change to the existing function. The task would do all the work and cast a completion signal. Rejected: `execute_mutation_plan` mutates `state.agent.state` directly during waves and threads the modified state through return values. Running it in a Task breaks state ownership (only the agent process can write its own state); fixing that requires the same restructuring this ADR prescribes anyway. The Task wrapper would only postpone the real refactor by one PR.

**Keep the wave orchestrator but cooperatively yield between waves.** Introduce a "yield to mailbox between waves" primitive so the orchestrator processes mailbox messages without unwinding. Rejected: cooperative scheduling inside a single signal-handler call is fundamentally a workaround. The natural OTP primitive is "split the work into separate handler invocations," which is what the state machine does.

**Per-pod GenServer dedicated to mutation orchestration.** The agent's mailbox stays free; a sibling process owns the wave loop. Rejected: introduces a new process to coordinate, more failure modes, more state to keep in sync. The existing AgentServer with signal-driven state-machine logic does the same job with no new processes.

**Keep `cast_and_await` selectors polling state for completion.** Don't introduce lifecycle signals; just keep the slice's `mutation.status` field and have callers `cast_and_await` with selectors that check it. Rejected: selectors run on every signal that crosses the agent's pipeline, not only when state changes — wasteful when 99% of signals don't touch the slice. Lifecycle signals + pattern-matched subscribe means the selector only fires on the relevant event. Aligns with the ADR's stated "Redux-style explicit subscribe" model.

**Single-step mutations only (deprecate multi-node atomicity).** Skip the wave concept entirely; expose `Pod.start_node/2` and `Pod.stop_node/2` as the only public API; let users compose their own multi-node flows. Rejected: pod mutations as a transactional unit are the user-facing concept. The internal implementation now uses single-step primitives, but the *API* still provides the multi-node mutation as a coherent operation with its own success/failure signal. Two layers, one for power users, one for the common case.

**New AgentServer primitive `cast_and_subscribe/6`** that atomically registers a subscription and casts a signal in one call. Rejected for now: subscribe-then-cast in user code already gives race-free semantics (the lifecycle signal can't fire before the trigger signal is processed, and the subscription registers in a synchronous `GenServer.call`). The convenience win is real but small; if a future caller pattern wants the atomic single call, it's an additive primitive that doesn't break anything in this ADR.
