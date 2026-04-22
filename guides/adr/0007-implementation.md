# 0007 implementation plan

Companion doc to [ADR 0007](0007-agent-lifecycle-is-signal-driven.md).
Breaks the migration into concrete commits. Each commit is scoped to
one logical change, lands green, and leaves the codebase in a
consistent state.

Target: 11–12 commits across four phases. Phase 5 (final deprecation
removal) is deferred to a future major release and not part of this
stack.

## Status tracker

Tick each box when the corresponding commit lands on `origin/main`.
The ADR's `Implementation:` field in its front matter progresses
`Pending → Partial → Complete` as phases land.

- [ ] 1.1 — Emit lifecycle signals from AgentServer
- [ ] 1.2 — `AgentServer.await_ready/2` helper
- [ ] 2.1 — Rewrite the 6 failing tests against `await_ready/2`
- [ ] 3.1 — Add new plugin callbacks with safe defaults
- [ ] 3.2 — Wire `Jido.Persist` to use `to_persistable` / `from_persistable`
- [ ] 3.3 — Migrate `Jido.Pod.Plugin`: reconcile moves into `after_start`
- [ ] 3.4 — Migrate `Jido.Thread.Plugin` to `to_persistable`
- [ ] 3.5 — Migrate `Jido.Memory.Plugin` to new callbacks
- [ ] 3.6 — Deprecate old plugin callbacks
- [ ] 4.1 — `AgentServer.init/1` loads slice from storage
- [ ] 4.2 — Remove `Lifecycle.Keyed.maybe_restore_agent_from_storage`
- [ ] 4.3 — Remove `restored_from_storage` from external contract
- [ ] 4.4 — `InstanceManager.build_child_spec` stops coordinating thaw

Phase boundaries:
- After Phase 1 (1.1, 1.2): ADR 0007 moves to `Implementation: Partial`.
- After Phase 2 (2.1): the 6 pod thaw tests go green.
- After Phase 3 (3.1–3.6): the plugin contract shift is in place.
- After Phase 4 (4.1–4.4): two thaw paths collapse into zero and
  `Implementation:` moves to `Complete`. Phase 5 is deferred.

## Phase 1 — Lifecycle signals + `await_ready/2`

**Goal:** Publish the `starting`/`ready`/`stopping` signals. Provide
`await_ready/2` as the synchronous barrier. No behavior changes yet;
agent and plugin callbacks continue to work as-is.

### Commit 1.1 — Emit lifecycle signals from AgentServer

Add three internal emission points inside `AgentServer`:

- `jido.agent.lifecycle.starting` in `init/1` **after** `State.from_options/3`
  returns but before `{:ok, state, {:continue, :post_init}}`. Data:
  `%{agent_module: atom, id: string, resumed: boolean}`. `:resumed` is
  true iff the slice was loaded from storage with a non-empty state
  (derived from the existing `restored_from_storage` flag; this field
  is for observability only, agents must not branch on it — see ADR
  0007's "fresh vs resume invisible" principle).
- `jido.agent.lifecycle.ready` at the **end** of
  `handle_continue(:post_init, state)`, after crons scheduled, parent
  notified, and lifecycle.mod's `handle_event(:started, state)` has
  returned. Data: `%{agent_module: atom, id: string}`.
- `jido.agent.lifecycle.stopping` at the **top** of `terminate/2`,
  before any lifecycle cleanup runs. Data:
  `%{agent_module: atom, id: string, reason: term}`.

Dispatch: cast to self via the normal signal pipeline, so `signal_routes`
can hook them. Source: `/agent/<id>`.

Files:
- `lib/jido/agent_server.ex` — three emission calls.
- `lib/jido/agent_server/signal/lifecycle.ex` — new module for the
  three signal-type string constants + validation (mirrors shape of
  `agent_server/signal/child_started.ex`).

Tests:
- `test/jido/agent_server/lifecycle_signals_test.exs` — new file.
  Subscribes to each of the three types, boots an agent, asserts
  emission order (`starting` → `ready` → `stopping` on graceful stop),
  asserts `:resumed` flag correctness for fresh and thawed cases.

Verification:
- `mix test` — no regressions.
- New test file passes.

### Commit 1.2 — `AgentServer.await_ready/2` helper

Add a new public function mirroring `await_completion/2` and
`await_child/3`.

```elixir
@spec await_ready(server(), keyword()) :: :ok | {:error, term()}
def await_ready(server, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, Defaults.agent_server_await_timeout_ms())
  waiter_id = make_ref()

  with {:ok, pid} <- resolve_server(server) do
    try do
      GenServer.call(pid, {:await_ready, waiter_id}, timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(pid, {:cancel_await_ready, waiter_id})
        {:error, :timeout}
    end
  end
end
```

Server side: new `state.ready_waiters` map (keyed by monitor_ref);
new `handle_call({:await_ready, waiter_id}, ...)` that either returns
`:ok` immediately (if already ready) or parks the caller. The ready
signal emission in Commit 1.1 picks up `state.ready_waiters`, replies
`:ok` to each, and drains the map.

Files:
- `lib/jido/agent_server.ex` — `await_ready/2`, `handle_call`,
  `handle_cast({:cancel_await_ready, _})`, and wake-up inside the
  ready-emission path.
- `lib/jido/agent_server/state.ex` — add `ready_waiters: %{}` +
  `ready?: boolean` (so callers arriving post-ready short-circuit).
- `lib/jido/agent_server.ex` DOWN handler — drain `ready_waiters`
  when a caller pid dies.

Tests (add to `test/jido/await_test.exs` or new `await_ready_test.exs`):
- `await_ready` returns `:ok` when called after ready already fired.
- `await_ready` parks and wakes when called before ready.
- `await_ready` returns `{:error, :timeout}` when ready never fires.
- `await_ready` cleans up the waiter on timeout (map drained).
- `await_ready` returns `{:error, :noproc}` on dead target (via
  Signal.Call-style monitor — reuse `AgentServer.resolve/1`).

Verification:
- `mix test` green.
- Grep `state.ready_waiters` — only touched by the three designated
  functions (wake in ready emission, park in handle_call, drain in
  handle_cast + DOWN).

## Phase 2 — Use `await_ready/2` to fix the 6 failing tests

**Goal:** Prove `await_ready/2` works by removing the race in the 6
failing pod thaw tests. No changes to production code in this phase —
only test rewrites.

### Commit 2.1 — Rewrite the 6 failing tests against `await_ready/2`

Tests (each assertion peeks at `state.children` immediately after the
pod comes back from storage; replace with `await_ready` + assertion):

- `test/jido/pod/runtime_test.exs:454` — `test restored parent pods re-adopt surviving nested pod nodes`
- `test/jido/pod/runtime_test.exs:740` — `test thaw restores only the requested pod partition when the same key exists twice`
- `test/jido/pod/runtime_test.exs:????` — `test thaw restores pod topology immediately and only root ownership needs pod-level re-adoption`
- `test/jido/pod/runtime_test.exs:????` — `test same pod key can exist across partitions and keeps runtime lookups isolated`
- `test/jido/pod/runtime_test.exs:????` — `test nested pod nodes inherit partition and allow the same pod key across partitions`
- `test/jido/pod/mutation_runtime_test.exs:????` — `test failed runtime materialization keeps the persisted topology and returns a failed report`

Shape of rewrite:

```elixir
# Before:
{:ok, restored_pid} = Pod.get(manager, "group-restore")
{:ok, restored_state} = AgentServer.state(restored_pid)
assert restored_state.children.nested.pid == nested_pid

# After:
{:ok, restored_pid} = Pod.get(manager, "group-restore")
:ok = AgentServer.await_ready(restored_pid, timeout: 1_000)
{:ok, restored_state} = AgentServer.state(restored_pid)
assert restored_state.children.nested.pid == nested_pid
```

The `state.children` read stays (it's still the right thing to
assert); it just now runs after the `ready` barrier.

Files:
- `test/jido/pod/runtime_test.exs` — 5 tests.
- `test/jido/pod/mutation_runtime_test.exs` — 1 test.

Verification:
- `mix test test/jido/pod/runtime_test.exs test/jido/pod/mutation_runtime_test.exs`
  → 21 tests, 0 failures.
- `mix test` full suite → 6 fewer failures than at `be37376`.

**Note:** Phase 2 fixes the symptom. It does NOT fix the architectural
problem (agent modules still know about thaw, plugin contract is
still on_checkpoint/on_restore). Phase 3/4 do.

## Phase 3 — Plugin contract shift

**Goal:** Replace `on_checkpoint/2` / `on_restore/2` with
`to_persistable/1`, `from_persistable/1`, `after_start/1`. Migrate
in-tree plugins. Deprecate (but do not remove) the old callbacks.

### Commit 3.1 — Add new plugin callbacks with safe defaults

In `Jido.Plugin`:

```elixir
@callback to_persistable(slice_state :: term()) :: term()
@callback from_persistable(persisted :: term()) :: term()
@callback after_start(server_state :: map()) :: map()

# Default implementations generated by `use Jido.Plugin`:
def to_persistable(state), do: state
def from_persistable(persisted), do: persisted
def after_start(server_state), do: server_state
```

Mark all three `@optional_callbacks`.

Files:
- `lib/jido/plugin.ex` — three callbacks + default generators.

Tests:
- `test/jido/plugin_test.exs` (or new file) — a plugin with no
  overrides uses the identity/no-op defaults; a plugin that overrides
  each returns the overridden value.

Verification: `mix test` green.

### Commit 3.2 — Wire `Jido.Persist` to use `to_persistable` / `from_persistable`

Replace calls to `plugin.on_checkpoint/2` inside the agent module's
default `checkpoint/2` (currently in `lib/jido/agent.ex:1057`) with
calls to `plugin.to_persistable/1`. Same for `on_restore/2`.

Semantic mapping:
- Old `{:externalize, key, pointer}` → new `to_persistable` returns
  `{:externalize, key, pointer}`. `Persist` still handles the
  externalize path. Plugins that return any other term get stored
  inline (that's what `:keep` meant).
- Old `:drop` → new `to_persistable` returns `nil` (or a sentinel
  like `:__dropped__`). `Persist` does not store the slice.
- Old `on_restore/2` of pointer → new `from_persistable/1` of pointer
  or stored term. Plugin distinguishes internally based on shape.

Behavior must stay identical during this commit — old callbacks still
work, new callbacks are added alongside. Dispatch precedence: if
`to_persistable/1` is overridden, use it; else fall back to
`on_checkpoint/2`.

Files:
- `lib/jido/persist.ex` — update `create_checkpoint` and
  `restore_from_checkpoint`.
- `lib/jido/agent.ex` — update the default `checkpoint/2` and
  `restore/2` generators to walk plugins using the new callbacks.

Tests:
- Existing Persist tests must still pass without modification.
- New test: a plugin with only `to_persistable/1` + `from_persistable/1`
  (no old callbacks) round-trips correctly.

Verification: `mix test` green.

### Commit 3.3 — Migrate `Jido.Pod.Plugin`: reconcile moves into `after_start`

Today, pod reconciliation is triggered externally
(`Pod.get` → `start_agent` → AgentServer boots → reconcile happens
*outside* the plugin). Under ADR 0007, the plugin owns it.

Changes:
- `Jido.Pod.Plugin` gains `after_start(server_state)` that calls
  `Jido.Pod.Runtime.reconcile(server_state, ...)`.
- `Jido.Pod.Runtime.reconcile/2` — change step 1 for each topology
  node to unconditional registry lookup: if alive → `adopt_child`;
  if not → spawn via `SpawnManagedAgent` directive. Today the
  survivor branch exists but is wrapped in conditions; move it to
  the top and make it universal.
- External callers of reconcile (`Pod.reconcile/2` public API) stay —
  they're for explicit user-triggered reconciliation, not lifecycle.

Files:
- `lib/jido/pod/plugin.ex` — `after_start/1` callback.
- `lib/jido/pod/runtime.ex` — reconcile's step-1 hoisting.

Tests:
- `test/jido/pod/runtime_test.exs` — existing tests should still pass
  (survivor adoption, fresh spawn, topology reconciliation).
- New test: pod with one node starts, `await_ready` resolves,
  `state.children` has the node. No explicit `Pod.reconcile` call
  anywhere in the test.

Verification:
- `mix test` green.
- The 6 phase-2 tests still pass.

### Commit 3.4 — Migrate `Jido.Thread.Plugin` to `to_persistable`

Move the `{:externalize, :thread, pointer}` logic from
`on_checkpoint/2` to `to_persistable/1`. Move the pointer-follow logic
from `on_restore/2` to `from_persistable/1`.

Files: `lib/jido/thread/plugin.ex`.

Tests: `test/jido/thread/plugin_test.exs` (or equivalent) — round-trip
still works.

Verification: `mix test` green.

### Commit 3.5 — Migrate `Jido.Memory.Plugin` to new callbacks

Memory plugin currently returns `:keep`. New `to_persistable/1` is
identity (default), so the override can just be deleted.

Files: `lib/jido/memory/plugin.ex` — remove `on_checkpoint/2`.

Verification: `mix test` green.

### Commit 3.6 — Deprecate old callbacks

Emit a compile-time warning (or deprecation annotation) when a plugin
module defines `on_checkpoint/2` or `on_restore/2`, pointing users at
the new callbacks.

Files:
- `lib/jido/plugin.ex` — `__using__` macro detects old callback
  definitions post-compile and emits `IO.warn(...)` or uses
  `@deprecated`.

Verification:
- `mix test` green.
- Compile the jido_playground app (path dep) and verify no deprecation
  warnings fire for in-tree plugins (since they've been migrated).

## Phase 4 — Collapse the two thaw paths

**Goal:** `AgentServer.init/1` owns slice loading. `InstanceManager`
stops deciding whether to pre-thaw. `Lifecycle.Keyed.init` stops
having a fallback thaw. The `restored_from_storage` flag disappears
from the external contract.

### Commit 4.1 — `AgentServer.init/1` loads slice from storage

New logic in `AgentServer.init/1`:

1. If `opts.agent` is a struct → use it (fresh-provided struct case,
   e.g. test agents built manually). Skip storage load.
2. Else if `opts.storage` + `opts.persistence_key` are set →
   `Jido.Persist.thaw/3` on them. If `:ok, agent` → use it.
   If `:not_found` → fall through to (3).
3. Else → `agent_module.new(id: opts.id, state: opts.initial_state || %{})`.

The `restored_from_storage` opt becomes derived (true iff path 2
returned `:ok`); emit it to `state.lifecycle.starting` signal data,
but don't use it elsewhere.

Files:
- `lib/jido/agent_server.ex` — rework `init/1` to include the
  three-way branch. Likely a new helper `load_or_create_agent/1`.
- `lib/jido/agent_server/options.ex` — add `persistence_key` option
  alongside existing `storage`.

Tests:
- New: `AgentServer.start_link(agent: %MyAgent{...})` — direct struct
  path.
- New: `AgentServer.start_link(agent_module: MyAgent, storage: ..., persistence_key: ...)`
  with existing checkpoint → loads from storage.
- New: same opts with no checkpoint → creates fresh.
- Existing Lifecycle.Keyed-driven thaw test should still pass.

Verification: `mix test` green.

### Commit 4.2 — Remove `Lifecycle.Keyed.maybe_restore_agent_from_storage`

With 4.1, the fallback thaw path is redundant. Delete the function
and the init call site.

Files:
- `lib/jido/agent_server/lifecycle/keyed.ex` — drop
  `maybe_restore_agent_from_storage/1` and its call from `init/2`.

Tests: existing thaw tests should still pass (because 4.1 replaced
the behavior).

Verification:
- `mix test` green.
- Grep `maybe_restore_agent_from_storage` — gone.

### Commit 4.3 — Remove `restored_from_storage` from external contract

The flag was an internal cue. Now that it's only used for the
starting-signal `:resumed` data field, derive it locally in init
and stop plumbing it through opts/state.

Files:
- `lib/jido/agent_server/options.ex` — remove the field.
- `lib/jido/agent_server/state.ex` — remove the field.
- `lib/jido/agent/instance_manager.ex` — remove from `@reserved_agent_opts`
  and from `build_child_spec/5`'s opts list.
- `lib/jido/agent_server/lifecycle/keyed.ex` — anywhere it read the
  flag, use a local derivation.

Verification:
- `mix test` green.
- Grep `restored_from_storage` — only appears inside init as a local
  variable (or not at all).

### Commit 4.4 — `InstanceManager.build_child_spec` stops coordinating thaw

With 4.1–4.3, `maybe_thaw/3` inside InstanceManager is also redundant
— it used to pre-thaw so it could set `agent:` in the child_spec.
AgentServer now handles thaw itself; InstanceManager just passes
`storage` + `persistence_key`.

Files:
- `lib/jido/agent/instance_manager.ex` — delete `maybe_thaw/3`, remove
  the `agent_or_nil` branch in `build_child_spec/5`, pass
  `persistence_key` instead of `pool_key`/storage-dance.

Tests:
- All InstanceManager tests should pass without modification.
- New: InstanceManager with storage but no prior checkpoint → fresh agent.
- New: InstanceManager with storage + prior checkpoint → thawed agent.
  Same test you'd have written before, just verifies the same
  externally-observable behavior.

Verification: `mix test` green.

## Phase 5 — Deferred (future major release)

**Goal:** Remove the deprecated callbacks entirely.

1. Remove `Jido.Agent.checkpoint/2` / `restore/2` callbacks.
2. Remove `Jido.Plugin.on_checkpoint/2` / `on_restore/2` callbacks.
3. Update docs to reflect that the plugin contract is
   `to_persistable/1`, `from_persistable/1`, `after_start/1` only.

Not in this stack. Ship when a breaking-change major release is
otherwise due.

## Verification across the stack

At end of Phase 4:

```bash
cd /Users/jova/sandbox/jido
mix compile --warnings-as-errors   # clean (with pre-existing unused-arg exception in pod/runtime.ex:851)
mix test                           # all tests pass, 6 fewer failures than at be37376
```

Grep smoke checks:

- `AgentServer.state(` in `lib/jido/` — count drops by ~5 from current
  (Await −3 from commit 3/commit 4, TopologyState −2 from commit 2;
  Phase 1–4 of this plan don't add new callers).
- `on_checkpoint` in `lib/jido/` — appears only in deprecated
  behavior declarations + plugins that haven't migrated (there
  shouldn't be any after commit 3.5).
- `restored_from_storage` in `lib/jido/` — zero occurrences after 4.3.

Manual smoke in `jido_playground`:

```bash
cd /Users/jova/sandbox/jido_playground
mix deps.update jido   # pick up path dep changes
mix test               # exercises the real external surface
```

## Order-of-operations notes for the implementing session

- Phases 1 → 2 → 3 → 4 must happen in order. Each relies on the
  previous.
- Inside Phase 3, commits 3.3–3.5 (plugin migrations) can happen in
  any order; each is independent.
- Inside Phase 4, commits 4.1 → 4.2 → 4.3 → 4.4 should happen in
  order to avoid breaking intermediate states.
- Phase 2 (test rewrite) deliberately lands *between* signal emission
  and plugin migration so the 6-test regression is fixed early and
  visibly, even though the root cause isn't fully addressed until
  Phase 3.3 moves reconcile into `after_start`.

## Known open questions

None blocking. If any arise during implementation, they should be
resolved inline via ADRs 0008+ if they constitute new decisions, or
via commit-message notes if they're tactical.
