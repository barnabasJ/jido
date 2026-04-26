# 0021. Cross-boundary reads project a narrow view; waits subscribe — never the full struct, never poll

- Status: Accepted
- Implementation: Pending — tracked by [task 0014](../tasks/0014-no-full-state-no-polling-pod-runtime-and-tests.md).
- Date: 2026-04-26
- Related ADRs: [0006](0006-external-sync-uses-signals.md), [0016](0016-agent-server-ack-and-subscribe.md), [0020](0020-synchronous-call-takes-a-selector.md)

## Context

[ADR 0020](0020-synchronous-call-takes-a-selector.md) introduced the rule "every cross-boundary read takes a selector," with `call/4` and `state/3` as the synchronous primitives. The selector contract is `(State.t() -> {:ok, term()} | {:error, term()})` — what crosses the boundary is the selector's return value, not the agent server's internals.

Two patterns satisfy ADR 0020 *literally* but defeat its intent. Both showed up during the [task 0013](../tasks/0013-call-takes-selector-cast-and-await-retires.md) migration:

1. **Full-state selectors.** Writing `fn s -> {:ok, s} end` returns the entire `%AgentServer.State{}`. The boundary is technically explicit (the selector exists), but the projection is "give me everything" — same blast radius as the retired `state/1`. The caller still operates on a stale, full snapshot of cross-process state. `agent.state` reads on that snapshot look local but are reads against a value that may already be obsolete by the time the next line runs.

2. **Polling for state changes.** `eventually(fn -> ... AgentServer.state(pid, ...) ... end)` busy-waits for a predicate. Even with a narrow selector, this is a tight loop of `GenServer.call`s. Polling assumes the agent will eventually reach the predicate's true state, but provides no mechanism to react to *when* it does. If the state never reaches the expected value (because of a missed signal, a different code path, an incorrect predicate), the test fails by timeout instead of by missed-event symptom — masking the real bug rather than surfacing it.

These patterns are most common in tests but also appear in `lib/`. `Pod.Runtime` in particular threaded full `%State{}` snapshots through dozens of internal helpers — `TopologyState.fetch_topology(state)`, `resolve_runtime_server(server, state)`, `pod_event_metadata(state)`, `build_node_snapshots(state, topology)`, `emit_pod_lifecycle(server_pid, state, ...)`, `execute_runtime_plan(server_pid, state, ...)` — each of which actually only reads three or four fields. The full-state copy hides every single one of those cross-process boundaries inside what looks like local data access.

ADR 0020 turned the smell from invisible (`state/1` was the only API) to visible (`fn s -> {:ok, s} end` is now the marker). This ADR makes the next move: the marker is a violation, not an option.

## Decision

### 1. Selectors must project, not dump

A `call/4` or `state/3` selector that returns the entire `%State{}` is a code smell, not a valid use of the API. The boundary is a deliberate decision about what the *caller* needs from the *callee*'s internals — "everything" defeats the purpose.

Rules:

- A selector returns a tagged tuple over a value the caller actually uses (a slice value, a tuple of two fields, a typed projection struct).
- Returning `{:ok, s}` from a selector is **forbidden in `lib/` and forbidden in `test/`**. The grep `grep -rn "fn s -> {:ok, s} end" lib/ test/` is the regression check; it should return zero hits.
- Pod-level helpers (`Pod.fetch_state/1`, `Pod.fetch_topology/1`, `Pod.nodes/1`) wrap selector primitives with baked-in projections. The framework primitive enforces the discipline; helpers absorb the boilerplate so domain code is ergonomic.

For internal-runtime callers like `Pod.Runtime` that genuinely need several fields, the right shape is a small projection struct built once at the boundary:

```elixir
defmodule Jido.Pod.Runtime.View do
  @enforce_keys [:id, :registry, :partition, :jido, :agent_module, :topology]
  defstruct [:id, :registry, :partition, :jido, :agent_module, :topology]
end
```

`fetch_runtime_state/1` returns `{:ok, %View{}}` via a tailored selector that projects just those fields. Internal helpers' signatures change to take `View.t()`, not `State.t()`. Each helper's signature now advertises what it actually uses; readers no longer see `state.agent.state.foo` on a snapshot whose freshness is unspecified.

The view is a *type*, not a smart wrapper. It carries the data the caller has to its work — once construction is done, it's an immutable record. If a helper needs additional fields, they're added to the view explicitly, not by passing the underlying state through.

### 2. Waiting is signal-driven; never poll

`eventually` / `eventually_state` and any `Process.sleep` + `state` poll loop is **forbidden as a wait primitive for agent state**. Cross-process waits use `subscribe/4` (or its wrappers `await_ready/2`, `await_child/3`, `mutate_and_wait/3`) to react to the lifecycle / domain signal that *announces* the state change.

Rules:

- A test waiting for an agent to reach `status: :idle` subscribes to `jido.agent.lifecycle.ready` (or the `await_ready/2` helper that wraps it).
- A test waiting for a child to start subscribes to `jido.agent.child.started` via `await_child/3`.
- A test waiting for a mutation to complete uses `Pod.mutate_and_wait/3`, which subscribes to lifecycle signals internally.
- Where no natural signal exists for the wait condition, the right answer is **to add the signal**, not to keep polling. A signal is documentation of the state transition; polling hides which transition the test depends on.

`eventually/2` itself is not deleted — non-state waits (waiting for an external HTTP endpoint, an external scheduler firing, a process to die) are legitimate and have no signal channel. But `eventually_state/3` is deleted entirely from `test/support/eventually.ex`. The grep `grep -rn "eventually_state" test/` should return zero hits after the migration.

### 3. Boundary smell markers

Both anti-patterns leave grep-able fingerprints:

| Pattern | Forbidden in | Grep |
|---|---|---|
| Full-state selector | `lib/` and `test/` | `fn s -> \{:ok, s\} end` |
| State-polling helper | all of `test/` | `eventually_state` |
| Sleep-based polling for state | all of `test/` | `Process.sleep` near `AgentServer.state` |

These greps are the regression check. If they grow back, the principle is being violated.

### 4. Migration recipe

For full-state callers in `lib/`:

1. Identify the actual fields the caller needs from `%State{}`.
2. Define a typed projection struct in the caller's namespace (e.g. `Pod.Runtime.View`).
3. Build the projection at the boundary via a tailored selector.
4. Update internal helper signatures to take the view, not `State.t()`.
5. Verify the cross-process snapshot is now strictly minimal.

For polling tests:

1. Identify what state transition the test is waiting for.
2. Find (or add) the signal that announces that transition.
3. Replace the `eventually_state` poll with `subscribe/4` + `assert_receive` (or one of the `await_*` helpers).
4. If no signal exists and adding one isn't justified, document why and use a tailored selector with `eventually` (not `eventually_state`) — but this should be the rare exception.

For full-state reads in test code (the `{:ok, state} = AgentServer.state(pid, fn s -> {:ok, s} end); assert state.foo` pattern):

1. Replace each call with a targeted selector that projects only the field(s) the assertion touches.
2. The assertion then operates on the projected value, not the full struct.

## Consequences

- **`Pod.Runtime` rewritten around a `View` struct.** `fetch_runtime_state/1` returns `{:ok, %View{}}`; internal helpers' signatures change to take `View.t()`. The cross-process boundary is named once, at the top of each public entry point.

- **Tests subscribe instead of polling.** Existing `eventually_state` callsites move to `subscribe/4` / `await_ready/2` / `await_child/3` waits. The migration surfaces tests that were polling in places where no signal existed — that's a coverage gap in the framework's signal vocabulary, not a property of the test. Fix the framework, not the test.

- **Tests use targeted selectors.** The pattern `{:ok, state} = AgentServer.state(pid, fn s -> {:ok, s} end); assert state.foo` becomes `{:ok, foo} = AgentServer.state(pid, fn s -> {:ok, s.foo} end); assert foo`. Each assertion explicitly names what it depends on; refactors to underlying state shape break only the tests that actually depend on the changed fields.

- **`eventually_state/3` deleted from `test/support/eventually.ex`.** `eventually/2` survives for external-system waits.

- **`pending_acks` field stays gone** (already deleted in [task 0013](../tasks/0013-call-takes-selector-cast-and-await-retires.md)). This ADR doesn't reintroduce ack-table style coordination — `subscribe/4` is the ambient wait primitive.

- **Test stability improves.** Polling loops are racy by construction — they answer "did this happen yet?" instead of "tell me when this happens." Subscription-based waits eliminate the race window: the subscriber is registered before the trigger and gets the event exactly once.

- **Audit trail in tests.** A subscriber names the signal it waits on; a poller doesn't. Reading a subscribe-based test tells you which transition the test exercises; reading a poll-based test tells you only what end state is acceptable, not how it got there.

## Alternatives considered

**Allow full-state selectors as a documented escape hatch.** Reasoning: sometimes the caller really does want everything (REPL inspection, debug dumps). Rejected: even REPL inspection should explicitly write `fn s -> {:ok, s} end` as a one-off and earn the comment explaining why. Treating it as discouraged-but-allowed in production code makes the discipline aspirational rather than enforced. The grep regression check is the discipline.

**Keep `eventually_state/3` as a fallback for "I can't figure out the right signal."** Rejected: the polling anti-pattern's worst feature is that it works *most of the time*. Keeping the primitive available means new code reaches for it whenever subscribing is "harder." Removing the primitive forces the right design conversation up front — either the signal exists (use it), or it doesn't (add it).

**Make the projection struct a generic `Jido.AgentServer.Projection`.** Rejected: the projection's field set is determined by the consumer's needs. A Pod runtime view has different fields than a worker pool view than a test inspection view. Per-consumer view structs keep each view's contract narrow and grep-able.

**Defer until a polling test causes a real race-condition incident.** Rejected: the cost of writing the rule is one ADR; the cost of debugging the eventual race is unbounded. Codify before the next incident.

**Keep `eventually_state/3` but warn at compile time.** Rejected: warnings get filtered out. Grep regressions are louder. Delete the helper, keep the discipline mechanical.
