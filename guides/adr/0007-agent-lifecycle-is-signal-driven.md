# 0007. Agent lifecycle is signal-driven; thaw is invisible to the agent module

- Status: Proposed
- Date: 2026-04-22
- Related commits: TBD (regression exemplified at `d85907f`)

## Context

Six tests in the pod thaw/restore + nested-pod-partition family
(`test/jido/pod/runtime_test.exs`, `test/jido/pod/mutation_runtime_test.exs`)
regressed on 2026-04-21 starting at commit `17bbff7` (ADR 0001:
children boot with parent pre-set). All six share one failure mode:
the test brings a pod back from storage, immediately peeks at
`state.children`, and finds it empty or stale.

`17bbff7` was correct in direction — replacing a post-init
`GenServer.call` to `AgentServer.adopt_child` with a
`jido.agent.child.started` signal emitted from the child's `post_init`
— but it removed a synchronous barrier without adding a replacement.
Before the change, `reconcile` ended with a blocking adopt that
populated `state.children` before returning. After, the child's signal
travels back asynchronously, and nothing outside the server knows
when the round-trip is complete. The 6 failing tests are the concrete
symptom; the root cause is that **"agent is ready" is not a point in
time anyone can observe**.

More broadly, the current code leaks thaw-as-a-concern into the agent
module:

- `Jido.Persist` owns byte orchestration (get checkpoint, call
  `restore/2`, rehydrate thread).
- `Jido.Agent.InstanceManager.build_child_spec/5` decides whether to
  pass the thawed struct or nil to `AgentServer` and flips
  `restored_from_storage: true`.
- `AgentServer.init/1` initialises all runtime maps empty regardless
  of whether this was a fresh start or a resumption — `state.children`,
  `cron_monitors`, `signal_router`.
- Agent modules optionally implement `checkpoint/2` and `restore/2`,
  and `use Jido.Agent` generates defaults that only serialise the
  agent struct.

The result: every user agent that wants custom persistence has to know
about thaw even though the mechanism is infrastructure. Every fresh
start and every resume converge on the same empty-runtime-state
snapshot, and whatever puts children back (reconcile, adopt, or a
child-started signal) does so asynchronously with no "done" marker.

## Decision

Two rules, together.

**Rule 1 — Agent-oblivious thaw.** The agent module does not own thaw.
`checkpoint/2` and `restore/2` callbacks are removed from the
`Jido.Agent` public surface; their functionality lives in
`AgentServer` (for runtime state) and in plugins via existing
`Jido.Plugin.on_checkpoint/2` (for per-slice externalisation).
InstanceManager stops passing "thawed struct or nil"; it passes a
`persistence_key` and `storage` and lets `AgentServer.init/1` decide
how to start. Fresh vs. resume becomes a branch inside the server, not
a decision the caller makes. The `restored_from_storage` flag stays as
an internal cue, not part of the external contract.

**Rule 2 — Lifecycle transitions are signals, ready is a point.** The
server emits:

- `jido.agent.lifecycle.initializing` — at the top of `init/1`.
- `jido.agent.lifecycle.thawing` — entered when storage returned a
  checkpoint and restore is about to start (sibling of `initializing`,
  not of `ready`; observers that want to distinguish fresh vs. resume
  hook this).
- `jido.agent.lifecycle.ready` — emitted **after** `init/1` +
  `handle_continue(:post_init, ...)` + any plugin-driven
  reconciliation have all completed. From ready onward, the invariant
  holds: `state.children` reflects the children the agent expects to
  have; every cron spec in storage is registered; every subscription
  has been re-established.
- `jido.agent.lifecycle.stopping` — at the top of `terminate/2`.

Callers that need to wait for "ready" use the existing
`Jido.Signal.Call` machinery or a new
`AgentServer.await_ready/2` modelled on `await_completion/2` and
`await_child/3` (ADR 0006). The failing 6 tests convert from
state-peek to ready-wait; their assertions about `state.children`
move behind the `ready` barrier, so the signal round-trip that the
post-17bbff7 flow depends on has time to complete before any
assertion runs.

For pods specifically: the `Pod.Plugin` subscribes to its own host's
`jido.agent.lifecycle.thawing` (or equivalent post-init hook) and
triggers `Pod.Runtime.reconcile/2` synchronously as part of the
lifecycle transition. `ready` fires only after reconcile emits
`jido.pod.reconcile.completed` (which already exists, ADR 0004). This
gives a clean composition: each layer contributes a transition; the
composition of transitions is `ready`.

## Consequences

- Agent authors stop writing `checkpoint/2` / `restore/2` entirely for
  the common case. They get fresh/resume parity for free. Authors
  with externalisation needs write a plugin.
- `InstanceManager.build_child_spec` simplifies — no more
  "maybe thaw first" branch in the glue layer. One code path for
  fresh and resume.
- The 6 failing tests (see commit `17bbff7` onward) become green once
  they await `ready` instead of peeking at state. More broadly,
  state-peek tests everywhere in the codebase can be rewritten against
  the `ready` barrier, and new tests won't race by default.
- The server's semantics get sharper:
  `GenServer.start_link({Jido.AgentServer, ...})` returning means the
  pid exists and basic init ran; it does NOT mean ready. Callers that
  care about ready wait for the signal. This matches how
  `await_completion/2` and `await_child/3` already work — same shape,
  new trigger.
- `jido.agent.lifecycle.thawing` gives observers a hook to tell fresh
  from resume without coupling to `restored_from_storage` (an
  implementation detail that leaks out of state today).
- Cost: every agent pays one extra signal emit at boot
  (`initializing` + `ready`, plus `thawing` on resume). Two-to-three
  signals per agent-start is negligible against the clarity gained.
- Migration: the removal of `Jido.Agent.checkpoint/2` / `restore/2`
  callbacks is a breaking change. Recommended phased approach:
  1. Emit the lifecycle signals and add `await_ready/2`. Agent
     callbacks stay as-is; AgentServer calls them internally.
  2. Rewrite the 6 failing tests against `await_ready/2`.
  3. Move `checkpoint/2` / `restore/2` behaviour into AgentServer +
     plugins. Mark the agent-level callbacks deprecated, update
     `use Jido.Agent` to stop requiring them.
  4. Remove the callbacks in a later major release.

## Alternatives considered

- **Make reconcile synchronous in `handle_continue(:post_init, ...)`.**
  Cheapest fix; restores pre-17bbff7 behaviour. But it locks the
  semantics of "ready" to whichever synchronous operation runs in
  post_init, making it inextensible. Plugins can't participate in
  "ready" without adding to a central procedural sequence. The signal
  model composes; the procedural barrier doesn't.

- **Keep `checkpoint/2` / `restore/2` on agents, just add lifecycle
  signals.** Minimal change, gets us a `ready` signal. Leaves every
  user agent with knowledge of thaw it shouldn't need. Fails the
  agent-oblivious half of the goal.

- **Fix only the 6 failing tests (have them await `child_started`
  signals or use `AgentServer.await_child/3`).** Smallest scope. It
  would unblock the test suite without codifying any direction. The
  tests are the canary, though — other callers (user code, docs
  examples) have the same race latent. A test-only fix leaves them
  armed.

- **Synchronous `GenServer.start_link` that blocks until ready.**
  Tempting for the call-site ergonomic, but it serialises startup
  across what should be a concurrent boot. Pods with many nodes would
  take much longer to come up. Publish `ready` as a signal; let
  callers opt into waiting.
