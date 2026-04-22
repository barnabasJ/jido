# 0006. External sync uses signals and events, not state-dig or polling

- Status: Accepted
- Implementation: Partial — see "Implementation status" below
- Date: 2026-04-21
- Related commits: `7eff5b4` (ADR), `af2e7cb` (TopologyState via signal),
  `fcf1a94` (Await children query + Signal.Call :noproc),
  `d85907f` (await_child replaces poll_for_child)

## Context

Two related antipatterns still live in `lib/jido/**` after ADRs 0002
and 0003.

**State-dig.** ADR 0002 introduced `Jido.Signal.Call.call/3` and ADR 0003
moved server-state access into the directive layer via
`%Directive.Reply{}`. `Pod.Runtime.nodes/1` and `lookup_node/2` migrated
as proof-of-concept. An audit of remaining `AgentServer.state/1` callers
in `lib/jido/` turns up ~13 call sites:

| Site | Fields read | Shape |
|---|---|---|
| `Jido.Await.lookup_child_pid/2` | `state.children` | state-dig |
| `Jido.Await.get_children/1` | `state.children` | state-dig |
| `Jido.Await.get_child/2` | `state.children` | state-dig |
| `Jido.Await.alive?/1` | — | liveness check |
| `Jido.Pod.TopologyState.fetch_topology/1` (server) | topology | state-dig |
| `Jido.Pod.TopologyState.fetch_topology/1` (module) | topology | state-dig |
| `Jido.Pod.Runtime.ensure_node/3` | topology + server_pid | orchestration |
| `Jido.Pod.Runtime.reconcile/2` | topology + server_pid | orchestration |
| `Jido.Pod.Runtime.teardown_runtime/2` | topology + server_pid | orchestration |
| `Jido.Pod.Runtime.build_parent_ref/5` | `parent_state.id` | bootstrap |
| `Jido.Pod.Runtime.register_child/3` | child metadata | bootstrap |
| `Jido.Pod.Mutable.mutate/3` | pod state | orchestration |
| `Jido.AgentServer` docs example | example only | doc |

State-dig cases all reach for one or two fields of `%State{}` the caller
has no business knowing about.

**Sleep-loop polling.** `Jido.Await.poll_for_child/4` calls
`lookup_child_pid/2` and `Process.sleep(50)` until the child appears.
The right shape for "wait until condition holds" already exists at
`AgentServer.await_completion/2`: the server parks the caller in
`state.completion_waiters`, a lifecycle transition wakes them, zero
sleeps. Child-appearance is the same shape — `jido.agent.child.started`
already fires uniformly per ADR 0001, so the server can wake
child-waiters off the same event.

`AgentServer.stream_status/2` also uses `Process.sleep`, but its contract
is "emit snapshots at interval" — that's a stream-shaped API, not
synchronisation. Out of scope.

## Decision

**Read.** External callers that need to ask an agent a question use
`Jido.Signal.Call.call/3` with a typed query signal and
`%Directive.Reply{}` builder (ADR 0003). Direct `AgentServer.state/1`
is justified only for:

1. Liveness checks that read no fields (e.g. `Await.alive?/1`).
2. Bootstrap metadata from a *different* agent during spawn, where a
   signal round-trip doubles a one-shot cost and the caller already
   holds the target pid (e.g. `Pod.Runtime.build_parent_ref/5`,
   `register_child/3`). Flag with a one-line comment at the call site.
3. Agent-internal debugging.

`state/1` stays in the module as an escape hatch but is no longer the
recommended API for introspection. Callers migrate one at a time.

**Wait.** External callers that need to block until a condition holds
use event-driven waiters parked in server state (the
`completion_waiters` pattern), woken by the same internal lifecycle
signals that produce observable events elsewhere. `Process.sleep`-based
polling of state is disallowed for synchronisation. Interval-based
observation (`stream_status`) is a different contract and is exempt.

This ADR lands the straightforward migrations against those rules:

- `TopologyState.fetch_topology/1` server clause reroutes through the
  existing `jido.pod.query.topology` signal.
- `Await.get_children/1`, `get_child/2`, and the private
  `lookup_child_pid/2` route through a new `jido.agent.query.children`
  signal answered via a `%Reply{}` directive.
- `Await.child/4` stops polling. A new `AgentServer.await_child/3`
  modelled on `await_completion/2` parks the caller in a
  `state.child_waiters` map keyed by child tag; the child-registration
  path that already emits `jido.agent.child.started` wakes matching
  waiters.

## Consequences

- `lib/jido/await.ex` drops its `Process.sleep` and the `poll_for_child`
  helper. The remaining waiters follow the same event-driven shape.
- Callers that used to pattern-match against `%State{}` internals now
  match on typed reply signals. Future struct changes don't ripple
  outward.
- The children-query signal is universal to all agents (any agent can
  have a `state.children` map). It lives in `lib/jido/agent_server/`
  alongside the cancel / control actions, not under `Pod`.
- Deferred to follow-up ADRs:
  - `Pod.Runtime.ensure_node/3`, `reconcile/2`, `teardown_runtime/2`
    thread state through multi-step orchestration. Each needs topology
    *and* runtime-server resolution *and* event metadata; converting in
    place requires either multiple queries or a composite one.
  - `Pod.Mutable.mutate/3` is already on the ranked follow-up list as a
    full rewrite on `Signal.Call.call/3`.
  - `AgentServer.stream_status/2` — if we want an observable stream of
    status changes, do it via a long-lived signal subscription, not an
    interval.

## Alternatives considered

- **Subscribe-then-block in `Await.child/4`.** Client-side: subscribe
  the caller's pid to `jido.agent.child.started`, `receive` until a
  matching tag arrives, unsubscribe. Works, but pushes subscription
  bookkeeping into every caller and races against children that were
  already registered before the subscription attached. The waiter-map
  pattern already handles both (already-present → reply immediately;
  future-event → park) and mirrors `await_completion/2` exactly, so
  there's one shape instead of two.

  *ADR 0010 adds a general subscribe primitive. The subscribe-too-late
  race is addressed for per-signal waits by `cast_and_await/4`'s
  atomic registration. `child_waiters` has a different convergence
  story (already-present vs. future-event) and stays as-is; the new
  primitives are for consumer-side waits, not a `child_waiters`
  migration.*
- **Long-poll via `Signal.Call.call/3` with deferred reply.** Action
  stashes the `%Reply{}` directive in plugin state; a later wake-up
  builds and dispatches it. Elegant in theory but requires plumbing
  through plugin checkpoint/restore and re-dispatch on lifecycle
  events. `child_waiters` sits in `%State{}` where the completion
  waiters already live — smaller surface, same shape.
- **Deprecate `AgentServer.state/1` outright.** Would force all callers
  to migrate in a single sweep. Runtime orchestration and `Mutable` are
  not one-line fixes; bundling them with the state-dig migration would
  delay both. Keeping `state/1` as a documented escape hatch and
  migrating callers one at a time keeps each ADR small.

## Implementation status

**Shipped:**

- [x] `Jido.Pod.TopologyState.fetch_topology/1` (server clause) uses
  `Signal.Call.call` with the existing `jido.pod.query.topology` signal.
  — `af2e7cb`
- [x] `Jido.Await.get_children/1` and `Jido.Await.get_child/2` use a
  new `jido.agent.query.children` signal. Route registered as a
  builtin via `AgentServer.SignalRouter.add_builtin_routes/1`.
  — `fcf1a94`
- [x] `Jido.Signal.Call.call/3` monitors the target pid and returns
  `{:error, :noproc}` on DOWN instead of blocking until timeout.
  `AgentServer.resolve/1` exposed as public helper.
  — `fcf1a94`
- [x] `Jido.Await.child/4` uses event-driven
  `AgentServer.await_child/3` in place of `poll_for_child` sleep loop.
  `state.child_waiters` parks callers; `maybe_notify_child_waiters/3`
  wakes them on child registration (from either
  `jido.agent.child.started` or `handle_call({:adopt_child, ...})`).
  — `d85907f`
- [x] `Jido.Await.alive?/1` keeps direct `state/1` call, documented as
  Category B (liveness check, not a state read).

**Deferred to follow-up ADRs:**

- [ ] `Pod.Runtime.ensure_node/3`, `Pod.Runtime.reconcile/2`, and
  `Pod.Runtime.teardown_runtime/2` still call `AgentServer.state/1`
  directly. These orchestrate multi-step work that threads state
  through many helpers — not a pure query. Will likely be addressed as
  a consequence of ADR 0007 (pod reconcile moves into plugin
  `after_start` callback; orchestration paths restructure around that).
- [ ] `Pod.Mutable.mutate/3` still uses a hand-rolled ETS lock with an
  internal cast/await dance. Rewrite on `Signal.Call.call/3` with an
  idle/in-flight state machine in plugin state. Own ADR needed.
- [ ] `build_parent_ref/5` ([runtime.ex:625](../../lib/jido/pod/runtime.ex))
  and `register_child/3` ([runtime.ex:798](../../lib/jido/pod/runtime.ex))
  still call `AgentServer.state/1` during directive execution to read
  bootstrap metadata from another agent. Category B per this ADR —
  keep with a justifying comment. Low priority.
- [ ] `AgentServer.stream_status/2` uses `Process.sleep` in a
  `Stream.repeatedly`. ADR 0010 provides the long-lived
  `AgentServer.subscribe/4`; the helper should be rebuilt on top of a
  subscription with a status-snapshot selector.
