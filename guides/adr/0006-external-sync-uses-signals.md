# 0006. External sync uses signals and events, not state-dig or polling

- Status: Accepted
- Date: 2026-04-21
- Related commits: TBD

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
