# Task 0006 — Lifecycle signals + `await_ready/2` + drop storage from AgentServer

- Commit #: 6 of 9
- Implements: [ADR 0015](../adr/0015-agent-start-is-signal-driven.md) — start is signal-driven; no thaw distinction
- Depends on: 0000, 0001, 0002, 0003, 0004 (chain-build at init/1 top), 0005 (`Jido.Middleware.Persister` + Thread transform integration)
- Blocks: 0007
- Leaves tree: **red** (thaw/hibernate tests still depend on removed paths until C8)

## Goal

Three outcomes:

1. AgentServer emits `jido.agent.lifecycle.{starting, ready, stopping}` signals at the canonical phase boundaries, routing each through the middleware chain.
2. `Jido.AgentServer.await_ready/2` helper lets callers block on `ready`.
3. **Drop storage entirely from AgentServer** (per W7 resolution). `AgentServer.init/1` always constructs fresh via `agent_module.new(...)`. The Persister Plugin (if declared) has a middleware half that blocks synchronously on `Jido.Persist.thaw/hibernate` during `lifecycle.starting` / `lifecycle.stopping` — mutating `ctx.agent` before calling `next`. Downstream middleware in the same chain pass sees post-thaw state.

After this commit: fresh start and resume from checkpoint are indistinguishable to slices, plugins, middleware, and the agent module. There's one code path (no `load_or_initialize_agent` branching). Storage is a middleware concern entirely.

## Files to modify

### `lib/jido/agent_server.ex`

#### Lifecycle signal emissions

**Emission ordering in `init/1`** (per SS3 + W7 — chain built first; storage is a plugin concern, not an AgentServer concern):

1. `Options.new`, `hydrate_parent_from_runtime_store`, read `options.agent_module` (required; no branching).
2. **`build_middleware_chain(agent_module, options)`** — pure compile-time fn composition over three sources: `agent_module.middleware() ++ options.middleware ++ plugin_middleware_halves(agent_module.plugins())`. Raises on duplicate modules (C4). There is no `options.plugins` — runtime plugin injection was dropped in round 4 (typing constraint).
3. `agent_module.new(id: options.id, state: options.initial_state)` — **always fresh**. No pre-merge of runtime plugin configs (there are none). The `Jido.Middleware.Persister` middleware (if declared or runtime-injected via `Options.middleware:`) thaws later by pattern-matching `lifecycle.starting`.
4. `State.from_options(options, agent_module, agent, middleware_chain: chain)` — chain threaded onto `%State{}`.
5. `maybe_register_global`, `maybe_monitor_parent`.
6. **emit `jido.agent.lifecycle.starting`** — routes through the chain. Ctx enters with schema-default slice state; if `Jido.Middleware.Persister` is declared and positioned appropriately in the chain, it **blocks on thaw IO** during this pass, replacing `ctx.agent` with the thawed struct before calling `next`. Downstream middleware (positioned after Persister) sees post-thaw state in `ctx.agent`; upstream middleware sees pre-thaw. No children, no subscriptions, no router yet regardless.
7. **emit `jido.agent.identity.partition_assigned`** — payload `%{partition: state.partition}`. Routes through chain. By this point, if Persister ran, `state.agent` reflects thawed state (via ctx→state sync at prior pass's unwind).
8. `{:ok, state, {:continue, :post_init}}`.

**`handle_continue(:post_init, state)`** (emission ordering):

1. `SignalRouter.build` ([line 1050](../../lib/jido/agent_server.ex))
2. `start_plugin_children` ([line 1054](../../lib/jido/agent_server.ex))
3. `start_plugin_subscriptions` ([line 1057](../../lib/jido/agent_server.ex))
4. `register_plugin_schedules` and `register_restored_cron_specs` ([lines 1070-1071](../../lib/jido/agent_server.ex))
5. `maybe_persist_parent_binding` ([line 1072](../../lib/jido/agent_server.ex))
6. `notify_parent_of_startup` ([line 1074](../../lib/jido/agent_server.ex)) — emits `jido.agent.child.started`
7. **emit `jido.agent.lifecycle.ready`** — at this point children are reconciled, subscriptions live, middleware has observed `starting` and all the intervening steps
8. `State.set_status(:idle)`

**Invariant: thaw completes before `ready`.** The Persister middleware half blocks on thaw IO synchronously during the `lifecycle.starting` chain pass — by the time that pass returns control to `init/1`, `ctx.agent` (and therefore `state.agent` after the ctx→state sync) reflects thawed state. `init/1` then returns `{:ok, state, {:continue, :post_init}}`; `handle_continue(:post_init)` does its other init work; emits `ready`. Any middleware or action observing `ready` sees post-thaw state reliably. (Thaw IO failure surfaces as an emitted `jido.persist.thaw.failed` signal; boot continues with fresh agent state unless the user subscribes and reacts.)

**`terminate(reason, state)`**:

1. **emit `jido.agent.lifecycle.stopping`** with payload `%{reason: reason}` at the very top. If `Jido.Middleware.Persister` is in the chain, its handler blocks synchronously on `Jido.Persist.hibernate/4` here. Framework opinion: **hibernate should be fast**. If storage is slow, users must raise the agent's `shutdown_timeout` in the supervisor's child_spec; otherwise the supervisor kills the process mid-write (default timeout 5s) → partial checkpoint.
2. existing teardown (child cleanup, etc.)

Emissions route through the **middleware chain** — they run through the same `on_signal/4` wrap as any other signal. This is what lets slices and plugins react to lifecycle via ordinary `signal_routes` declarations.

```elixir
defp emit_through_chain(state, signal) do
  ctx = build_ctx(state, signal)
  {new_ctx, directives} = state.middleware_chain.(signal, ctx)
  state_with_agent = %{state | agent: new_ctx.agent}
  {:ok, executed_state} = execute_directives(directives, signal, state_with_agent)
  executed_state
end
```

#### `await_ready/2`

```elixir
@spec await_ready(server(), timeout()) :: :ok | {:error, :timeout}
def await_ready(server, timeout \\ 5_000) do
  pid = resolve_pid(server)
  ref = Process.monitor(pid)
  GenServer.cast(pid, {:register_ready_waiter, self(), ref})

  receive do
    {:jido_ready, ^ref} -> Process.demonitor(ref, [:flush]); :ok
    {:DOWN, ^ref, :process, ^pid, reason} -> {:error, {:down, reason}}
  after
    timeout ->
      GenServer.cast(pid, {:cancel_ready_waiter, ref})
      Process.demonitor(ref, [:flush])
      {:error, :timeout}
  end
end
```

Internal state field on `%State{}`: `ready_waiters :: %{reference() => pid()}`. If `ready` has already fired by the time `await_ready` is called (server is past `:idle`), reply immediately.

Shape mirrors [`await_completion/2`](../../lib/jido/agent_server.ex) (to be deleted in C7) and `await_child/3` at [line 433+](../../lib/jido/agent_server.ex).

#### Storage is not loaded in `init/1` — it's a Plugin concern

Currently, `Jido.Agent.InstanceManager.maybe_thaw/3` fetches the thawed agent and passes it as an `agent:` option ([instance_manager.ex:324-376](../../lib/jido/agent/instance_manager.ex)). After this commit, **InstanceManager never thaws synchronously**. Per W2 resolution (option γ), `agent:` is removed from Options entirely — callers pass `agent_module:` only. Per W7 + round-4 pivot, `Options.storage:` and `Options.persistence_key:` are also removed — storage config moves inside the Persister middleware via `Options.middleware: [{Jido.Middleware.Persister, %{storage: ..., persistence_key: ...}}]`.

`AgentServer.init/1` always constructs a fresh agent via `agent_module.new/1`. Storage is never touched directly; the Persister middleware (if declared compile-time or injected via `Options.middleware:`) observes `lifecycle.starting` and blocks on `Jido.Persist.thaw/4` synchronously, replacing `ctx.agent` with the thawed struct before calling `next`:

```elixir
def init(raw_opts) do
  opts = if is_map(raw_opts), do: Map.to_list(raw_opts), else: raw_opts

  with {:ok, options} <- Options.new(opts),
       {:ok, options} <- hydrate_parent_from_runtime_store(options),
       agent_module <- options.agent_module,  # required, always present
       chain <- build_middleware_chain(agent_module, options),  # C4 — 3-source composition; options supplies runtime middleware only
       # Always fresh. No conditional thaw here — Jido.Middleware.Persister (if in chain)
       # blocks on thaw IO when lifecycle.starting routes through and replaces
       # ctx.agent with the thawed struct before calling next.
       agent <- agent_module.new(id: options.id, state: options.initial_state),
       {:ok, state} <- State.from_options(options, agent_module, agent, middleware_chain: chain),
       :ok <- maybe_register_global(options, state) do
    state = maybe_monitor_parent(state)

    # Persister's on_signal for lifecycle.starting runs here if configured.
    # ctx.agent gets replaced with the thawed struct; that state syncs back via
    # the chain-return → state.agent sync documented in C4.
    state = emit_through_chain(state, lifecycle_starting_signal(state))
    state = emit_through_chain(state, identity_partition_assigned_signal(state))

    {:ok, state, {:continue, :post_init}}
  end
end
```

**Deleted in this commit** (relative to pre-refactor):
- `resolve_agent/1` at [agent_server.ex:2359-2385](../../lib/jido/agent_server.ex) — no branching between atom/struct; always `agent_module.new/1`.
- `load_or_initialize_agent/2` — not added. AgentServer has no storage code path.
- No call to `Jido.Persist.thaw/3` anywhere in AgentServer.

### `lib/jido/agent/instance_manager.ex`

- **Delete** `maybe_thaw/3` ([lines 382-402](../../lib/jido/agent/instance_manager.ex)).
- In `start_agent/3` ([line 319+](../../lib/jido/agent/instance_manager.ex)) and `build_child_spec/5` ([line 341+](../../lib/jido/agent/instance_manager.ex)):
  - Stop computing `agent_or_nil`.
  - Pass `agent_module: config.agent` (per W2 resolution — `agent:` removed entirely).
  - **Drop** `storage:` and `persistence_key:` as top-level options.
  - **Add** `middleware: build_persister_middleware(config, key, partition)` via `Options.middleware:`:
    ```elixir
    defp build_persister_middleware(%{storage: nil}, _key, _partition), do: []
    defp build_persister_middleware(config, key, partition) do
      [{Jido.Middleware.Persister, %{
        storage: config.storage,
        persistence_key: manager_persistence_key(config.name, key, partition),
        transforms: config.transforms || %{}
      }}]
    end
    ```
    If the InstanceManager has no storage configured, no Persister middleware is injected. Config lives in the middleware's `opts`; no Slice to auto-merge.
  - **Ownership pattern — no double-declaration**: the chain's duplicate-module rule raises at init if the same module appears in both `agent_module.middleware()` and `Options.middleware:`. Concretely: agents managed by InstanceManager must NOT compile-time-declare `{Jido.Middleware.Persister, ...}` on `use Jido.Agent`; standalone agents that compile-time-declare Persister must NOT be spawned via InstanceManager. Two ownership patterns, mutually exclusive per agent module: (a) compile-time Persister for standalone / fixed-config agents, including tests; (b) runtime-injected Persister for pooled agents via InstanceManager with per-instance storage config. The migration guide (C8) calls this out so users don't trip over it. When the collision does occur, users see `Jido.Agent.DuplicatePluginError` with a message specifically explaining the Persister ownership trap (see C4).
  - Remove `restored_from_storage:` key from the opts list ([line 367](../../lib/jido/agent/instance_manager.ex)).
- `initial_state:` ([line 371-376](../../lib/jido/agent/instance_manager.ex)) now always passes through; AgentServer uses it in `agent_module.new/1`.

### `lib/jido/agent_server/lifecycle/keyed.ex`

- **Delete** `maybe_restore_agent_from_storage/1` and its helpers ([lines 184-216 plus helpers](../../lib/jido/agent_server/lifecycle/keyed.ex)).
- Simplify `init/2` ([line 37](../../lib/jido/agent_server/lifecycle/keyed.ex)) to: populate the lifecycle struct, start idle timer if appropriate. The lifecycle module is now purely for attachment tracking and idle timeout. **Thaw and hibernate are both Persister Plugin responsibilities** — the middleware half observes `lifecycle.starting` / `lifecycle.stopping` and blocks on IO.
- Any hibernate-on-shutdown code in the Keyed lifecycle ([currently in terminate-related handlers](../../lib/jido/agent_server/lifecycle/keyed.ex)) is removed — the Persister Plugin's middleware half handles it on `lifecycle.stopping`.

### `lib/jido/agent_server/state.ex`

- Remove `restored_from_storage` field ([lines 70-72](../../lib/jido/agent_server/state.ex)) from the schema.
- Remove the corresponding entry from `State.from_options/3` ([line 182](../../lib/jido/agent_server/state.ex)).

### `lib/jido/agent_server/options.ex`

- **Remove** `storage:`, `persistence_key:`, `restored_from_storage:` options entirely (per W7 — storage is a plugin concern).
- **Per W2 resolution**: remove `agent:` option entirely. Make `agent_module:` **required** (no `Zoi.optional()`). The schema becomes:
  ```elixir
  agent_module: Zoi.atom(description: "Agent module; required. Always constructed via new/1.")
  # agent: REMOVED
  # storage: REMOVED — use middleware: [{Jido.Middleware.Persister, %{storage: ..., persistence_key: ...}}]
  # persistence_key: REMOVED
  # restored_from_storage: REMOVED
  ```
- **Add `middleware:`** option (C4) — `[module() | {module(), opts_map}]`, default `[]`. Runtime-appended middleware-only modules.
- **No runtime `plugins:` option** (per round-4 pivot). Compile-time `plugins:` on the agent module stays. Rationale: runtime plugin injection would require dynamically extending `agent.state`'s typed schema — awkward to do cleanly. Middleware injection is safe (no state contribution), which is enough for Persister and other infrastructure concerns.
- Update `Options.new/1` callers in AgentServer and InstanceManager to pass the new shape.

### `lib/jido/pod/runtime.ex`

- `ensure_planned_agent_node/...` at [lines 582-611](../../lib/jido/pod/runtime.ex):
  - Step 1: registry lookup for the logical id (via `Jido.registry_lookup/2` or equivalent against the manager's registry). If alive, **adopt** — store pid in `state.children`, emit `jido.agent.child.started`, done.
  - Step 2: if not alive, spawn via existing `spawn_node/...` path.
  - Remove the current `snapshot.status == :adopted` branching — the branch decision is now just "alive yes / alive no".
- Reconcile emits `jido.pod.reconcile.started` / `.completed` / `.failed` as today. These are separate from the lifecycle signal namespace.

### `lib/jido/persist.ex`

- C2 dropped the forward-compat migration pass entirely (per round-2 W10 — no external users; fresh checkpoints only). `do_thaw/4` reads whatever shape is on disk; pre-refactor checkpoints are regenerated, not translated.
- `scheduler_manifest` handling ([lines 353, 544](../../lib/jido/persist.ex)) unaffected: cron specs live at their own reserved key that's neither migrated nor touched by lifecycle changes.

## Files to create

None beyond what was already delivered in C1–C5.

## Files to delete

None beyond the deletions in `instance_manager.ex` and `lifecycle/keyed.ex` listed above.

## Acceptance

- `mix compile --warnings-as-errors` passes
- Start an agent (with or without Persister configured): lifecycle signals emit in order `starting → ready`; `await_ready(pid)` returns `:ok`; grep the state struct and the Options schema — `restored_from_storage` / `storage:` / `persistence_key:` / `agent:` no longer exist.
- Stop the agent: `stopping` emits once at the top of `terminate/2`.
- Persister round-trip verification (thaw from real storage, hibernate completes durably) is covered by C8 integration tests, not this commit's acceptance — C6's scope is lifecycle emission and storage-removal, not Persister behavior.
- A slice declaring `signal_routes: [{"jido.agent.lifecycle.ready", {MyInit, []}}]` sees `MyInit` dispatched on start.
- A plugin whose `on_signal/4` pattern-matches `jido.agent.lifecycle.ready` has its middleware-half callback invoked when AgentServer emits `ready` through the chain — verifying Plugin modules are correctly wired into `middleware_chain` alongside user-declared middleware.
- `mix test` — **expect failures** in:
  - `test/jido/integration/hibernate_thaw_test.exs` (409 lines — rewritten in C8)
  - `test/jido/agent/instance_manager_test.exs` (any tests asserting `restored_from_storage` flag)
  - Pod reconcile tests that depend on the old `snapshot.status` branching

## Out of scope

- ack/subscribe primitives (→ C7)
- Test rewrites (→ C8)
- Per-signal or debounced hibernate strategies — this PR ships only `lifecycle.stopping`-triggered hibernate in Persister. Follow-up PR(s) add configurable strategies.

## Risks

- The lifecycle signals route through the middleware chain. Middleware that doesn't pattern-match the lifecycle types must call `next.(sig, ctx)` pass-through — otherwise startup crashes. The only middleware shipping in this PR is `Jido.Middleware.Retry`, which already pass-throughs non-matching signals. Verify this property with an integration test that boots an agent with `Retry` declared and asserts `lifecycle.starting`/`ready`/`stopping` all emit cleanly.
- **`starting` ctx minimalism**: middleware observing `starting` must not depend on post-init state (no children, no subscriptions, no router). The ctx contract at this stage is documented in C4. Breaking this contract (e.g., a middleware that reads `ctx.agent.state.children`) silently gets `%{}` and may misbehave — call it out in the middleware guide.
- `await_ready/2` called **after** the agent has already reached `:idle` must still return `:ok` synchronously. Handle by checking `state.status` at the time of the cast; reply immediately if already ready.
- **InstanceManager.get/3 semantics change — document, don't auto-await.** InstanceManager previously thawed *synchronously* before spawning the AgentServer. After this commit, thaw happens inside the Persister plugin's `lifecycle.starting` handler — during AgentServer's `init/1`, but after `agent_module.new/1` has produced a fresh agent. The spawn succeeds; the agent isn't "ready" (thawed + reconciled) until `await_ready/2` returns.

  `InstanceManager.get/3` deliberately keeps its existing semantics — returns the pid as soon as the process is alive, not "thawed and ready." The caller decides whether it needs ready-state (calling `await_ready/2`) or just liveness (sending signals without waiting). InstanceManager doesn't wrap `await_ready` automatically — it's not InstanceManager's concern.

  **Affected in-repo callsites** (grep'd from `lib/`):
  - [`lib/jido/pod.ex:110`](../../lib/jido/pod.ex) — `Jido.Pod` delegates to `InstanceManager.get`; update to call `await_ready` if Pod callers expect thawed state.
  - [`lib/jido/agent/directive.ex:461`](../../lib/jido/agent/directive.ex) — `%Directive.Dispatch{}` resolution via InstanceManager; determine whether dispatch-time readiness matters here.
  - [`lib/jido/pod/runtime.ex:307`](../../lib/jido/pod/runtime.ex) — Pod runtime uses `InstanceManager.lookup`; this is a liveness check, not a readiness check, so no change needed unless pod adoption semantics require thawed state.

  **Test callsites** (`test/` — 7 files) are updated in C8 as part of the test rewrite phase.

  **Migration guide (C8)** adds a section explaining: "If you had `InstanceManager.get/3` callers that assumed thawed state, insert `await_ready/2` between get and first-signal-send."
- Pod adopt-then-spawn has race: two parents trying to adopt the same child at once both see it alive in registry. Registry monitors the winner; the loser's adopt succeeds via `:already_started`. The existing `DynamicSupervisor.start_child → {:error, {:already_started, pid}}` path at [instance_manager.ex:332-334](../../lib/jido/agent/instance_manager.ex) handles this. Verify reconcile respects the same pattern.
- C3 deletes the `init_signal/0` helper (previously emitted by Strategy init). Double-check no test or doc still references it.
- **Hibernate-on-`terminate/2` vs supervisor shutdown timeout**: `lifecycle.stopping` emits at the top of `terminate/2` and routes through the chain — the Persister middleware blocks on `Jido.Persist.hibernate/4` synchronously. If hibernate IO exceeds the supervisor's shutdown timeout (default 5_000 ms), the process gets `:kill`'d mid-write and the checkpoint is partial. The framework doesn't enforce its own timeout (it would just trade one corruption mode for another). Users with slow storage must increase their supervisor's `shutdown:` value. Document the bound in `guides/middleware.md` and the migration guide. Spot-check during implementation: agent with realistic storage adapter completes hibernate well under 5_000 ms; flag if not.
