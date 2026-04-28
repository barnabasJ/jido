# Review findings — ADRs 0014–0016 plan

Review of [plan](~/.claude/plans/atomic-whistling-graham.md) and `guides/tasks/0001–0008` for inconsistencies, gaps, and feasibility.

Status key: **✅ resolved** / **🔄 in discussion** / **⏸ pending** / **❌ deferred**

---

## Show-stoppers

### SS1 — `Jido.Actions.Status.*` target after `:__strategy__` retires — ✅ resolved

**Original concern**: unclear where `MarkCompleted`/`MarkFailed` write after strategy retirement.

**Resolution**: actions are not used as signal_routes anywhere in-repo. They deep-merge `%{status: :completed}` into the agent's domain slice today. Under the new no-merge rule they would need rewriting; instead **delete them entirely** — convention can live in a migration-guide snippet.

**Follow-on decisions**:
- **No more deep-merge**. Slice actions receive their slice state, return the new slice state + directives. Tightens the Redux analogy — reducers always return full state.
- `Jido.Agent.ScopedAction` folds into `Jido.Action`. Every slice-touching action declares `path:`; gets `slice` explicitly; returns new slice.

### SS2 — Middleware opts plumbing — ✅ resolved

**Original concern**: `middleware: [{Persister, %{transforms: %{...}}}]` — how does Persister see `transforms`? `on_signal/3` had no opts arg.

**Resolution**: **`on_signal(signal, ctx, opts, next)` — 4 args**, opts as separate arg (not stuffed into ctx). Chain builder closes over each middleware's opts at construction:

```elixir
fn sig, ctx, next -> MyMiddleware.on_signal(sig, ctx, mw_opts, next) end
```

Clean separation: ctx = runtime per-signal (user, trace, tenant); opts = compile-time per-registration config. Consistent with the action callback `run(signal, slice, opts, ctx)`.

### SS3 — Middleware chain built too late vs. `init/1` lifecycle signals — ✅ resolved

**Concern**: ADR 0015 says `jido.agent.lifecycle.starting` emits at top of `init/1`; ADR 0014 says `identity.partition_assigned` emits "at `init/1` after partition resolved." Both route through middleware per ADR intent. My C4 built the chain in `post_init` — too late.

**Resolution**: **option (a)** — build chain at top of `init/1`, before any signal emission. Chain construction is pure function composition over compile-time middleware list + plugin instances; no runtime state required. Chain is a local variable in `init/1` until `State.from_options/3` threads it onto `%State{}`.

**Ctx contract at `starting`**: ctx has `agent` (schema defaults or thaw-loaded slice state) and runtime identity (partition, parent, orphaned_from). Children map is empty; subscriptions not yet active. Middleware authors observing `starting` must not depend on post-init setup. Documented in C4's ctx-shape section.

**Emission ordering** (post-refactor `init/1`):
1. `resolve_agent_module`
2. `build_middleware_chain(agent_module)` (pure compile-time fn composition)
3. `load_or_initialize_agent` (thaw or schema defaults)
4. `State.from_options(..., middleware_chain: chain)`
5. `register_global`
6. `monitor_parent`
7. **emit `jido.agent.lifecycle.starting`** (via chain)
8. **emit `jido.agent.identity.partition_assigned`** (via chain)
9. `{:ok, state, {:continue, :post_init}}`

Then `handle_continue(:post_init)`: router build, children, subscriptions, schedules, parent notify, **emit `jido.agent.lifecycle.ready`**, set `:idle`.

`terminate/2`: **emit `jido.agent.lifecycle.stopping`** at top.

---

## Critical findings

### C1 — Typo in `Jido.Await.completion/3` rewrite — ✅ resolved (trivial)

Passes `self()` to `AgentServer.unsubscribe/2`. Should pass `server`. Task 0007 gets corrected when next patched.

---

## Warnings

### W1 — C4-vs-C5 ordering problem — ✅ resolved (dissolved)

Deleting `Jido.Plugin.Legacy` shim in C4 left in-tree plugins with orphan `@impl Jido.Plugin.Legacy` annotations — broken under `--warnings-as-errors`.

**Resolution**: **no Legacy shim at all**. Don't rewrite the `Jido.Plugin` macro in C1; leave it untouched through C4. In-tree plugins continue to `use Jido.Plugin` with the old macro semantics (callback generation, `state_key:`, `mount/2`, etc.) compiling unchanged. C5 rewrites the `Jido.Plugin` macro AND migrates the 5 in-tree plugin files in the same commit — paired changes.

W1's entire problem disappears because there's no Legacy shim to delete.

### W2 — `agent_module` / `agent` struct split at `init/1` — ✅ resolved

Current `resolve_agent/1` in AgentServer returns `{:ok, agent_module, agent}` together, branching on whether `agent:` is atom or struct. C6's thaw collapse needs `agent_module` resolved before `load_or_initialize_agent/2` can run.

**Resolution**: **option (γ)** — require `agent_module:`, drop `agent:` entirely. Every caller passes a module atom; AgentServer always constructs via `agent_module.new(...)` (or thaws from storage). Pre-populated state goes via `initial_state:`, not via struct injection.

- `Options.agent_module:` — **required atom**; no default, no alias.
- `Options.agent:` — **removed**.
- `resolve_agent/1` in AgentServer deleted; replaced by a trivial `options.agent_module` lookup.
- `load_or_initialize_agent/2` uses `agent_module` exclusively (thaw with `Persist.thaw(storage, agent_module, key)` or `agent_module.new(id: id, state: initial_state)`).
- Test fixtures that built elaborate pre-populated structs migrate to `initial_state:` or add a factory that calls `new/1` with the right inputs.
- `InstanceManager.build_child_spec/5` already passes `agent_module: config.agent` — just needs `agent: config.agent` removed.

Scope impact: small edits in C4 (init/1 sketch) and C6 (thaw flow, Options schema). No new task doc.

### W3 — In-tree plugin `path/0` during C2–C5 transition — ✅ resolved (dissolved)

C2 was going to update `default_plugins` to key overrides by path. In-tree plugins don't export `path/0` until they migrate in C5.

**Resolution**: with the Legacy shim dropped (see W1), C2 **keeps `default_plugins` keyed by `state_key`** (no change to that mechanism). C5 flips the keying to `path` at the same time it migrates the plugin files and rewrites the `Jido.Plugin` macro — all paired. No derivation or fallback needed; no uneven intermediate state in the default_plugins mechanism.

### W4 — Action ctx needs `parent`, `partition`, `orphaned_from` — ✅ resolved

Under the new `run(signal, slice, opts, ctx)` shape with ctx threading, runtime identity fields are in ctx.

**Resolution**: middleware chain's initial ctx is seeded from `%State{}` by AgentServer — keys documented in the C4 "Ctx shape contract" section: `:agent`, `:agent_module`, `:agent_id`, `:partition`, `:parent`, `:orphaned_from`, `:jido`, plus `signal.extensions[:jido_ctx]` merged in. Directives that need `parent` (e.g., `emit_to_parent`) declare intent (`dispatch: :to_parent`) resolved at exec time by the executor reading `%State{parent:}`.

### W5 — Thread persistence approach inconsistency — ✅ resolved

Task 0005 showed two approaches and recommended MFA but had mixed examples. Now collapsed: Thread is a pure Slice; persistence uses Persister's MFA config.

**Resolution**: agent declares:

```elixir
middleware: [
  {Jido.Middleware.Persister, %{
    transforms: %{
      thread: {Jido.Thread.Persister, :externalize, :reinstate}
    }
  }}
]
```

`Jido.Thread.Slice` becomes `Jido.Thread.Slice` (no middleware half needed). `Jido.Thread.Persister` is a new module holding `externalize/1` and `reinstate/2`. Task 0005 updated accordingly.

### W6 — `child_waiters` migration; `Jido.Await` fate; selector contract refinement — ✅ resolved

Three coupled decisions:

**(a) `Jido.Await` deleted entirely.** Zero real consumers in `lib/` — the 5 test usages all test Await itself. The module bakes in opinionated policy (`:completed`/`:failed` atoms, `status`/`last_answer`/`error` field paths, domain-slice expectation) that belongs in user code, not the framework.

Delete:
- [lib/jido/await.ex](lib/jido/await.ex)
- `Jido.completion/3`, `Jido.all/3`, `Jido.any/3` wrappers in [lib/jido.ex](lib/jido.ex) (lines ~680-730)
- `AgentServer.await_completion/2` and `state.completion_waiters` (already planned in C7)
- `AgentServer.child_waiters` state field (see next)

Users who want "wait for terminal status" write a small helper over `subscribe/4` with `once: true` — their agent, their terminal convention, their selector.

**(b) `AgentServer.await_child/3` migrates to use `subscribe/4`.** Thin wrapper:

```elixir
def await_child(server, child_tag, opts \\ []) do
  case GenServer.call(resolve_server!(server), {:get_child_pid, child_tag}) do
    {:ok, pid} -> {:ok, pid}  # fast path
    :not_found ->
      selector = fn state ->
        case state.children do
          %{^child_tag => %ChildInfo{pid: pid}} -> {:ok, pid}
          _ -> :skip
        end
      end
      {:ok, ref} = AgentServer.subscribe(server, "jido.agent.child.started", selector, once: true)
      wait_once(ref, opts[:timeout])
  end
end
```

`state.child_waiters` field, `handle_call({:await_child, ...})`, `handle_cast({:cancel_await_child, ...})`, `maybe_notify_child_waiters/3` all deleted.

**(c) Selector contract refinement.** Final shape:

| Primitive | Selector return | Notes |
|---|---|---|
| `subscribe/4` | `{:ok, value} \| {:error, reason} \| :skip` | `:skip` keeps listening; fires auto-unsubscribe under `once: true` |
| `cast_and_await/4` | `{:ok, value} \| {:error, reason}` | Always fires the ack exactly once |

`once: true` on subscribe auto-unsubscribes on any fire (`{:ok, _}` or `{:error, _}`), but **not** on `:skip`.

### W7 — Storage lives in a Plugin (Slice + Middleware + Directives), not in AgentServer — ✅ resolved

Storage is entirely a plugin concern. AgentServer is storage-agnostic. The architecture follows the broader separation-of-concerns principle the user established: slices hold state, middleware bridges data with full-state visibility, directives do the actual work, actions orchestrate.

Changes:
- **`Options.storage:`, `Options.persistence_key:`, `Options.restored_from_storage:` removed** from `Options`.
- **`Options.plugins:`** — new runtime-injected plugins list, `[module() | {module(), config_map}]`. Merged with `agent_module.plugins()`. Triggers the same slice registration + config-merge behavior as compile-time plugins (Agent.new/1 seeds `agent.state[plugin.path]` from config).
- **`Options.middleware:`** — new runtime-injected middleware list, `[module() | {module(), opts_map}]`. Merged with `agent_module.middleware()`. Plain middleware modules only (middleware-only; no slice half).
- Chain builder composes: `agent_module.middleware() ++ options.middleware ++ plugin_middleware_halves(agent_module.plugins() ++ options.plugins)`. Duplicate module check across all four sources raises at init.
- **`AgentServer.init/1` never touches storage**. Always constructs fresh via `agent_module.new(id: id, state: initial_state)`. No `load_or_initialize_agent/2` helper.
- **`Jido.Plugin.Persister`** (new in C5) owns thaw AND hibernate through the full Plugin shape:
  - **Slice** at `path: :persister`: schema has `storage`, `persistence_key`, `transforms`, `status`. Seeded with per-instance config via auto-merge when declared in `plugins:` (compile-time or via `Options.plugins:`).
  - **Middleware half**: thin bridge. Principle applies: "middleware has whole-agent-state visibility; slices only their own." For Persister specifically the middleware half might be near-empty pass-through since config auto-merges into the slice at construction; kept for future extensibility.
  - **Actions** `Thaw`, `Hibernate`: routed on `jido.agent.lifecycle.starting` / `lifecycle.stopping`. Read the slice, emit `%Directive.Thaw{}` / `%Directive.Hibernate{}` directives.
  - **Directives**: `%Directive.Thaw{}` + `%Directive.Hibernate{}` structs, executors in `AgentServer.directive_executors` do the `Jido.Persist.thaw/3` / `.hibernate/4` IO and emit completion signals (`jido.persist.thaw.completed|failed`, etc.).
- **InstanceManager** passes `plugins: [{Jido.Plugin.Persister, %{storage: ..., persistence_key: ...}}]` via `Options.plugins:`. Runtime slice registration + config auto-merge handles the rest.

Ownership patterns separate cleanly:
- Compile-time declared Persister (fixed config): standalone agents, tests.
- Runtime-injected Persister (per-instance config): pooled agents via InstanceManager.
- Users don't do both for the same agent.

**`AgentServer.Lifecycle` module** (`Noop`, `Keyed`) stays — it handles idle-timeout tracking (attachments, idle timer), which is runtime state, not persistence. `Lifecycle.Keyed.maybe_restore_agent_from_storage/1` deletes (already planned in C6).

### W8 — `agent_server/status.ex` strategy coupling (queries.ex was a red herring) — ✅ resolved

Original concern misidentified the file. `agent_server/queries.ex` is 27 lines and only reads `state.children` — no strategy references. The real issue is `agent_server/status.ex` (122 lines), which is a public struct built entirely around `agent_module.strategy_snapshot(agent)` + `%Strategy.Snapshot{}`. All its public helpers (`status/1`, `done?/1`, `result/1`, `details/1`, `iteration/1`, `termination_reason/1`, `queue_length/1`, `active_requests/1`) read from the snapshot.

When C3 retires `Jido.Agent.Strategy`, the snapshot goes away — Status breaks.

**Resolution**: **(β) delete `Jido.AgentServer.Status` entirely**. Same reasoning as `Jido.Await` deletion: bakes in opinionated policy (strategy-style status vocabulary: `:waiting`/`:running`/`:success`/`:failure`/`done?`/`iteration`/etc.). Zero non-test consumers in `lib/` — only `AgentServer.status/1` (the public wrapper), the two status test files, and the retiring `fsm-strategy.livemd`. Users inspect `AgentServer.state/1` directly and build their own shape.

Deletions in C3:
- `lib/jido/agent_server/status.ex` (whole file)
- `AgentServer.status/1` public function at [agent_server.ex:507-520+](../../lib/jido/agent_server.ex)
- `infer_timeout_hint/1` at [agent_server.ex:469-476](../../lib/jido/agent_server.ex) — strategy-status-atom coupling

Deletions in C8:
- `test/jido/agent_server/status_test.exs`
- `test/jido/agent_server/status_struct_test.exs`

**`queries.ex` is left untouched** — nothing to audit.

### W9 — ctx/state protocol at ack-fire boundary — ✅ resolved

**Resolution**: locked in C4's "ctx/state sync at the outer boundary" section. The middleware chain owns `ctx.agent` during execution; after the chain returns, AgentServer syncs back:

```elixir
state_with_agent = %{state | agent: new_ctx.agent}
{:ok, executed_state} = execute_directives(dirs, signal, state_with_agent)
```

### W10 — Middleware return contract wraps agent in ctx — ✅ resolved

**Resolution**: `ctx.agent` is the source of truth during chain execution. The innermost `next` (core pipeline) reads `ctx.agent`, calls `cmd/2`, stores result as `ctx.agent` in the returned ctx. Documented in C4's revised `core_next` code sketch.

---

## Suggestions

### S1 — `plugin_subscriptions_test.exs` categorization — ✅ resolved

Added to C8's "Rewrite (substantive)" list: keep tests for static `subscriptions:` (survives as a Slice field); drop tests for dynamic `subscriptions/2` callback (retires with the old plugin surface).

### S2 — Pod plugin topology via `initial_state:` — ✅ resolved

The `use Jido.Pod` macro on the agent module overrides `new/1` to pre-seed `agent.state.pod` with `Jido.Pod.Plugin.build_state(topology(), %{})`. Topology is compile-time data, and this keeps the derivation at compile time (matches reality; enables standalone `cmd/2` in tests).

**`mount/2` retires entirely**, replaced case-by-case with four patterns:

| Pattern (old `mount/2` purpose) | Replacement |
|---|---|
| `{:ok, nil}` (Thread, Identity, Memory) | Delete the callback; schema defaults cover |
| Echo config into slice (BusPlugin) | `Agent.new/1` merges `{Plugin, config}` into `agent.state[plugin.path]` on top of schema defaults |
| Compile-time derivation from agent module (Pod) | `use Jido.Pod` macro overrides `new/1`, injects `initial_state: %{pod: ...}` before calling `super(opts)` |
| Runtime-derived (any future plugin) | Slice action routed on `jido.agent.lifecycle.starting` that writes state via a `StateOp.SetPath` directive |

Pod Plugin itself stays as a **Plugin** (Slice + Middleware) — not pure Slice. Its middleware half observes `lifecycle.starting` to run `Jido.Pod.Runtime.reconcile/2` (topology is already seeded by the macro at this point).

### S3 — Guide gaps — ❌ deferred (to post-refactor PR)

User is planning a broader guide overhaul after the refactor lands, so most guide updates defer. Kept in this PR:

- **New**: `guides/slices.md`, `guides/middleware.md`
- **Rewrite**: `guides/plugins.md` (the existing guide teaches the retired surface — can't stay)
- **Migration section in `guides/migration.md`** (required — existing users need a migration path)
- **Delete**: `guides/strategies.md`, `guides/custom-strategies.md`, `guides/fsm-strategy.livemd`

Deferred:
- `guides/agents.md`, `core-loop.md`, `configuration.md` — will reflect pre-refactor surface; stale until post-refactor pass
- `guides/your-first-plugin.md`, `phoenix-integration.md`
- `guides/await.md` — whole file may be deleted or refactored depending on post-refactor plans
- `guides/orphans.md`, `observability.md`, `observability-intro.md`
- `guides/runtime.md`, `runtime-patterns.md`, `storage.md`, `scheduling.md`

Accepts that these guides describe pre-refactor internals until a follow-up PR redoes them.

### S4 — ReAct example — ❌ deferred (to post-refactor PR)

Existing `test/examples/react/react_plugin_test.exs` is a 167-line skipped design-sketch moduledoc (pseudocode only, `@moduletag :skip`). References retired ADRs 0011/0012 but no code depends on it. Rewriting to an executable example depends on Retry middleware + SpawnTask directive + LoopTimeout middleware — all deferred. Leave the file alone in this PR; post-refactor PR decides rewrite/update/delete.

### S5 — Persister uses directives (`%Directive.Thaw{}`, `%Directive.Hibernate{}`) — ✅ resolved

Per the refined Persister architecture in W7: persistence is done via directives, not sync calls in middleware. Two new directive structs + executors:

- `lib/jido/agent/directive/thaw.ex` — `%Directive.Thaw{storage, persistence_key, agent_module, transforms, on_complete, on_error}`
- `lib/jido/agent/directive/hibernate.ex` — `%Directive.Hibernate{storage, persistence_key, agent, transforms, on_complete, on_error}`
- Executor modules under `lib/jido/agent_server/directive_executors/` (matching the existing pattern at [lib/jido/agent_server/directive_executors.ex](../../lib/jido/agent_server/directive_executors.ex))

Executors call `Jido.Persist.thaw/3` and `Jido.Persist.hibernate/4` respectively, merge result back into agent state (thaw case), and emit the `on_complete` / `on_error` signals.

### S6 — Retry middleware — ✅ resolved (shipped)

`Jido.Middleware.Retry` ships in C4 (not deferred). Minimal first-pass implementation: `:max_attempts` config, optional `:pattern` for signal filtering, immediate retry (no backoff). Backoff/jitter deferred to follow-up.

The C7 ack-once-on-retry test uses the real Retry module — no test stub needed. Separate unit test at `test/jido/middleware/retry_test.exs` covers retry-on-error, retry-until-success, max-attempts-exceeded, and pattern filtering.

**`LogErrors` and `StopOnError` dropped** per user direction — error-handling model deferred to follow-up PR. C4's `error_policy.ex` deletion has no direct replacement; migration guide includes a reference snippet for users who want to self-roll log-and-continue or stop-on-error middleware.

### S7 — CHANGELOG / version bump — ❌ deferred

Not in task docs. Probably out of scope.

### S8 — Credo config state — ❌ deferred

`mix credo --strict` acceptance may need config adjustments. Unknown state of credo config.

### S9 — Telemetry span shape changes — ✅ resolved (deferred per-middleware spans)

Option (γ): keep existing `[:jido, :agent_server, :signal, :start|:stop|:exception]` events at the outermost boundary of the middleware chain — same shape as today. No new per-middleware span events. Downstream telemetry consumers see the same events.

Per-middleware instrumentation (retry attempts, per-layer timings, skip fires) deferred to a dedicated observability follow-up PR.

Scope for this PR: note in C4 that existing telemetry at the outermost signal boundary is preserved verbatim; no new events added.

### S10 — Debug events through middleware — ❌ deferred

Current state has `debug_events` ring buffer. Middleware pipeline could emit per-layer debug events. Follow-up.

---

## Feasibility discoveries (new work in plan)

### F1 — Inline `jido_action` (~6K lines) — ✅ decision: inline

External dep defines `@callback run(params, context)`. To use the cleaner `run(signal, slice, opts, ctx)` signature without cross-repo coordination, inline jido_action core.

- Inline: `jido_action.ex` (Action behaviour), `jido_instruction.ex`, `jido_action/exec.ex` + subtrees, `schema`, `error`, `util`, `runtime`, `tool` — roughly 6,000 lines core
- Drop: `jido_tools/*` (arithmetic, files, req, workflow, lua, basic, action_plan) — reference implementations, not framework
- Maybe drop: `jido_plan.ex` (538 lines) — if Jido agents don't use multi-action plans
- Becomes the first commit — **new C0**

### F2 — Don't inline `jido_signal` (17K lines) — ✅ decision: keep dep

Too big to inline. `Jido.Signal` already has an `extensions: map()` field (CloudEvents extensions). Use `signal.extensions[:jido_ctx]` as the canonical location for per-signal ctx. Zero API churn to the dep.

### F3 — Ctx threading as universal principle — ✅ decision: apply everywhere

ctx flows through:
- Action: `run(signal, slice, opts, ctx)` — 4 args
- Middleware: `on_signal(signal, ctx, opts, next)` — 4 args
- Directive executor: `exec(%Directive{}, signal, ctx, server_state)` — ctx propagates to emitted signals' `extensions[:jido_ctx]`
- Slice / Plugin config: compile-time, no ctx

Origin: caller puts ctx on the triggering signal via `signal.extensions[:jido_ctx]` or new opt to `cast_and_await/4`. AgentServer extracts and seeds ctx at the top of the chain. Middleware can augment/strip. Emitted signals inherit by default.

---

## Decisions summary

| Decision | Decided |
|---|---|
| Delete `Jido.Actions.Status.*` | ✅ |
| No deep-merge — actions return full slice | ✅ |
| Action callback: `run(signal, slice, opts, ctx)` | ✅ |
| `Jido.Agent.ScopedAction` folds into `Jido.Action` | ✅ |
| Inline `jido_action` core (~6K); drop `jido_tools` | ✅ |
| Don't inline `jido_signal`; use `extensions[:jido_ctx]` | ✅ |
| Ctx threaded through actions, middleware, directives | ✅ |
| Middleware callback: `on_signal(signal, ctx, opts, next)` | ✅ |
| Chain builder closes over per-middleware opts | ✅ |
| New C0 commit — inline jido_action + ctx | ✅ |
| Middleware chain built at top of `init/1` (not post_init) | ✅ |
| Other warnings / suggestions | ⏸ to discuss |

## Commit plan revision

| # | Task | Status |
|---|---|---|
| C0 | Inline jido_action; unify action signature; ctx threading | **new** |
| C1 | Slice / Middleware scaffolding | existing |
| C2 | Flatten agent.state; `path:` required | existing |
| C3 | Retire Strategy; inline Direct | simpler (no merge branch) |
| C4 | Middleware pipeline; retire legacy hooks | existing + opts-as-arg |
| C5 | Migrate in-tree plugins | existing |
| C6 | Lifecycle signals + collapse thaw | existing |
| C7 | ack / subscribe primitives | existing |
| C8 | Tests, guides, ADR status | existing + delete Status tests + migration guide |
