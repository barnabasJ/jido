# Task 0004 — Single-tier middleware pipeline; retire legacy plugin hooks

- Commit #: 4 of 9
- Implements: [ADR 0014](../adr/0014-slice-middleware-plugin.md) — middleware chain, single tier `on_signal/4`
- Depends on: 0000, 0001, 0002, 0003
- Blocks: 0005, 0006, 0007
- Leaves tree: **red** (in-tree plugins still use the old `Jido.Plugin` macro until C5; related tests fail until C8)

## Goal

Replace `Jido.AgentServer`'s plugin-hook chain with a middleware chain built from `Jido.Middleware` modules plus the middleware halves of Plugins. Single-tier `on_signal/4` wrap — the outermost middleware wraps the entire core pipeline (`routing → cmd/2 → directive execution`). Retire the legacy `handle_signal/2`, `transform_result/3`, `on_before_cmd/2`, `on_after_cmd/3`, `on_checkpoint/2`, `on_restore/2`, `mount/2`, and `error_policy:`. Ship `Jido.Middleware.Retry`; error-handling replacement (`LogErrors` / `StopOnError`) is deferred to a follow-up PR per S6.

**Per SS3 resolution**: the middleware chain is built at the **top of `init/1`** (right after `resolve_agent_module`), not in `post_init`. The chain is a pure function of compile-time declarations; no runtime state required. Building it early lets `jido.agent.lifecycle.starting` and `jido.agent.identity.partition_assigned` signals (both emitted during `init/1`) route through the chain per ADR intent.

## Files to modify

### `lib/jido/agent_server.ex` (heaviest changes)

Replace the current plugin-hook pipeline with a middleware chain.

**Revised `init/1` ordering per SS3 + W7 + round-4 pivot** — chain built before any signal emission. Per W2, `agent_module` is required on Options. Per W7, AgentServer never touches storage — agent is always constructed fresh; `Jido.Middleware.Persister` (when declared compile-time or injected via `Options.middleware:`) blocks on thaw IO synchronously when `lifecycle.starting` routes through the chain, and replaces `ctx.agent` with the thawed struct before passing to `next`.

```elixir
def init(raw_opts) do
  opts = if is_map(raw_opts), do: Map.to_list(raw_opts), else: raw_opts

  with {:ok, options} <- Options.new(opts),
       {:ok, options} <- hydrate_parent_from_runtime_store(options),
       agent_module <- options.agent_module,   # required; no branching
       # Build chain from compile-time + runtime sources (duplicate-module detection inside).
       chain <- build_middleware_chain(agent_module, options),
       # Always fresh; Persister middleware (if declared or runtime-injected) will block on thaw
       # synchronously when the lifecycle.starting signal routes through the chain below.
       agent <- agent_module.new(id: options.id, state: options.initial_state),
       {:ok, state} <- State.from_options(options, agent_module, agent, middleware_chain: chain),
       :ok <- maybe_register_global(options, state) do
    state = maybe_monitor_parent(state)

    # Lifecycle + identity signals, both routed through the chain.
    # If Persister middleware is in the chain, its on_signal/4 handler for lifecycle.starting
    # blocks on thaw IO, replaces ctx.agent with thawed struct, emits completion/failure signal.
    state = emit_through_chain(state, lifecycle_starting_signal(state))
    state = emit_through_chain(state, identity_partition_assigned_signal(state))

    {:ok, state, {:continue, :post_init}}
  else
    {:error, reason} -> {:stop, reason}
  end
end

defp build_middleware_chain(agent_module, %Options{middleware: mw}) do
  plugin_halves = plugin_middleware_halves(agent_module.plugins())

  (agent_module.middleware() ++ mw ++ plugin_halves)
  |> compose_chain(&core_next/2)
end
```

> **Duplicate-module detection deferred.** Earlier drafts of this task raised
> `Jido.Agent.DuplicatePluginError` if a module appeared in more than one of
> the three sources, on the rationale that `InstanceManager` injecting
> `Jido.Middleware.Persister` could silently double-register against a
> compile-time declaration. That guarantee is worth re-evaluating in C5/C6
> when InstanceManager actually wires Persister; until then, the rule blocks
> legitimate same-module-different-opts uses (e.g. two `Retry` middlewares
> with different `pattern:` values). The chain composes whatever is declared,
> in order — duplicate-handling becomes a user concern.

- Delete `run_plugin_signal_hooks/2` ([line 1805+](../../lib/jido/agent_server.ex)) and `invoke_plugin_handle_signal/5` ([line 1887+](../../lib/jido/agent_server.ex)).
- Delete `run_plugin_transform_hooks/5` ([line ~1955+](../../lib/jido/agent_server.ex)).
- In `process_signal_common/2` ([line 1588](../../lib/jido/agent_server.ex)), replace the plugin-hook branching with a middleware-chain invocation:

  ```elixir
  defp process_signal_common(%Signal{} = signal, %State{middleware_chain: chain} = state) do
    # Seed ctx from the signal + server-level runtime identity (C0 ctx threading).
    signal_ctx = Jido.Signal.get_ctx(signal, %{})
    ctx =
      %{
        agent: state.agent,
        agent_module: state.agent_module,
        agent_id: state.id,
        partition: state.partition,
        parent: state.parent,
        orphaned_from: state.orphaned_from,
        jido: state.jido
      }
      |> Map.merge(signal_ctx)

    chain.(signal, ctx)
    # returns {ctx_updated, directives}
  end
  ```

  The chain is built **at the top of `init/1`** (not post_init — see SS3) and stored in `state.middleware_chain`. Build order: `state.agent_module.middleware() ++ plugin_middleware_in_declaration_order(state)`. Each entry is either a bare module (opts = `%{}`) or `{Mod, opts}`; the chain builder closes over opts per-middleware:

  ```elixir
  # C0 decision: opts is a separate explicit arg on on_signal/4.
  defp build_middleware_chain(entries, core_next) do
    Enum.reduce(Enum.reverse(entries), core_next, fn entry, acc_next ->
      {mod, opts} = normalize_entry(entry)
      fn sig, ctx -> mod.on_signal(sig, ctx, opts, acc_next) end
    end)
  end

  defp normalize_entry({mod, opts}) when is_atom(mod) and is_map(opts), do: {mod, opts}
  defp normalize_entry(mod) when is_atom(mod), do: {mod, %{}}
  ```

  Innermost `next` is the core pipeline:

  ```elixir
  core_next = fn sig, ctx ->
    case route_to_actions(state.signal_router, sig) do
      {:ok, actions} ->
        # agent_module.cmd/3 uses the inlined run(signal, slice, opts, ctx) shape (C3).
        # The third arg is a keyword list of runtime hooks that cmd/3 unpacks into the
        # per-action run/4 invocation:
        #   * ctx: the per-signal runtime context (seeded by AgentServer from state + signal extensions)
        #   * input_signal: the triggering signal; cmd/3 passes it as the first arg of run/4
        # ctx.agent is the mutable agent struct during chain execution; update it in ctx.
        {new_agent, directives} = state.agent_module.cmd(ctx.agent, actions,
          ctx: ctx, input_signal: sig)
        {%{ctx | agent: new_agent}, directives}

      {:error, reason} ->
        error = Jido.Error.routing_error("No route for signal", %{
          signal_type: sig.type, reason: reason
        })
        {ctx, [%Directive.Error{error: error, context: :routing}]}
    end
  end
  ```

  Each middleware wraps the next. Wrapping is pure function composition — no process boundaries, no message passing.

  **ctx/state sync at the outer boundary**: the chain returns `{new_ctx, directives}`. Before running directive execution, sync `new_ctx.agent` back into `%State{}`:

  ```elixir
  {new_ctx, dirs} = chain.(signal, ctx)
  state_with_agent = %{state | agent: new_ctx.agent}
  {:ok, executed_state} = execute_directives(dirs, signal, state_with_agent)
  ```
- `execute_directives/3` at [line 1637+](../../lib/jido/agent_server.ex) stays as-is (it's orthogonal — operates on directives returned from `cmd/2`); it just runs inside `core_next` rather than at a separate stage.

### Emitted signals re-enter the chain (uniform signal handling)

When a directive executor fires `%Directive.Emit{signal: Y}`, Y **always re-enters the middleware chain** — no bypass. Mechanism: the executor does `GenServer.cast(self(), {:signal, y_with_inherited_ctx})`; Y hits the mailbox, gets picked up as a fresh `handle_cast`, runs through `process_signal_common/2` → full chain with its own ctx seeding + own ack boundary.

Consequences:
- **Retry observes emitted errors.** If an action emits `"work.failed"`, Retry middleware sees it on Y's pass and can retry.
- **Persister observes completion.** `"jido.persist.thaw.completed"` gets the full chain pass; any middleware watching can react.
- **Every signal has one uniform observability path.** No special "internal vs external" category. Middleware doesn't need to know whether a signal came from outside or from a loop-back directive.
- **Acks are separate per pass.** If a caller did `cast_and_await` on X and X emits Y, X's ack fires on X's outer unwind; Y's pass has its own ack entry only if Y was itself issued via `cast_and_await` (which it wasn't — an emit from inside an action is a cast, not a cast_and_await). ADR 0016:59 documented the invariant; this is how it's mechanized.

Ctx inheritance: the emit-time ctx is attached to Y via `signal.extensions[:jido_ctx]` (C0's ctx threading); when Y re-enters and the chain extracts `signal.extensions[:jido_ctx]` to seed ctx, the original X's ctx carries through. Middleware can strip or augment before emitting.

**Consistency with ADR 0009**: self-cast places the signal in the Erlang mailbox (the only queue per 0009) where it's picked up by a future `handle_cast({:signal, _}, state)` and runs through `process_signal_async/2` inline — same pipeline as any externally-delivered signal. No new queue, no detour around the inline-processing rule.

### Middleware crash behavior

If a middleware's `on_signal/4` raises, the crash propagates to `process_signal_async/2`. The existing catch-block at [agent_server.ex:1519-1534](../../lib/jido/agent_server.ex) (preserved for the `[:jido, :agent_server, :signal, :exception]` telemetry emission, per S9) converts it to `{:stop, reason, state}` — the agent process crashes, its supervisor restarts it. No silent error-swallowing; no framework shield over user-provided middleware bugs.

Callers waiting via `cast_and_await/4` receive `{:error, {:agent_down, reason}}` via their DOWN monitor (task 0007 spec). Subscribers receive a monitored DOWN if they chose to monitor the agent.

Consistent with selector-crash behavior (task 0007's "no try/rescue around selectors" decision): user-provided code that raises takes down the agent. Framework does not try to recover from user bugs; standard OTP supervision handles it.

### `lib/jido/agent_server/state.ex`

- Add `middleware_chain :: (Signal.t(), map() -> {map(), [struct()]}) | nil` as a typed field on `%State{}`. **Populated at the top of `init/1`** (per SS3 resolution), before any lifecycle signal emission. Briefly nil only during `State.from_options/3`; set immediately after.
- Remove `error_policy` field ([lines 80-81](../../lib/jido/agent_server/state.ex)). Error handling is middleware now.

### `lib/jido/agent_server/options.ex`

- Remove `error_policy` option.
- Add **`middleware:`** option — `[module() | {module(), opts_map}]`, default `[]`. Runtime-appended middleware-only modules. InstanceManager uses this to inject Persister.
- **No `plugins:` option.** Compile-time `plugins:` on the agent module stays (for user-defined Plugins with their own Slice), but runtime plugin injection is *not* supported. Rationale: runtime plugins would need to dynamically extend `agent.state`'s typed schema — hard to do cleanly without either weakening typing or adding schema-merging machinery. Middleware doesn't add state, so runtime middleware injection is safe. Persister is middleware-only (no Slice), so runtime-injected via `Options.middleware:`.
- Duplicate-module detection across the three sources is **deferred** (see note above and the C5/C6 follow-up). The chain composes whatever is declared.

### `lib/jido/agent_server/error_policy.ex`

- **Delete entirely.** No direct replacement in this PR — error handling model deferred to a follow-up PR. Users who relied on `error_policy: :log_only` / `:stop_on_error` either:
  - Write their own ~10-line middleware in user space (pattern-match on `%Error{}` directives in the result; log or append `%Stop{}`)
  - Wait for the follow-up PR that formalizes the error-handling surface

The migration guide in C8 includes a reference snippet for the self-roll case.

### `lib/jido/agent.ex`

- Remove `on_before_cmd/2` and `on_after_cmd/3` from `@optional_callbacks` ([lines 445-452](../../lib/jido/agent.ex)).
- Remove their `@callback` declarations ([lines 344-369](../../lib/jido/agent.ex)).
- Remove the `checkpoint/2` and `restore/2` agent callbacks ([lines 403-452](../../lib/jido/agent.ex)) — custom checkpoint/restore is middleware now.
- Add `middleware:` option to `@agent_config_schema`: `Zoi.list(Zoi.any()) |> Zoi.default([])`. Accepts `module()` or `{module(), opts}`.
- **Generate `def middleware/0` accessor in `use Jido.Agent` `__using__` macro** (mirroring the existing `def plugins/0` at `agent.ex:555`). Returns the list verbatim from `@validated_opts[:middleware] || []`. Without this, `build_middleware_chain(agent_module, options)` in the AgentServer fails with `UndefinedFunctionError`.
- **Widen compile-time `plugins:` shape to accept `[module() | {module(), map()}]`**: today `plugins: [module()]` only; the chain builder closes over per-plugin config (opts for middleware half, initial config for Slice auto-merge), so the field must accept the `{Mod, config}` form. `Jido.Plugin`-valued plugins without config remain bare-module entries. `def plugins/0` returns the list verbatim.
- Two helpers (shown earlier in this doc) handle chain-entry normalization: `normalize_module/1` returns the bare module atom (used for duplicate-module detection via `group_by`), and `normalize_entry/1` returns `{mod, opts}` (used when composing the chain so each layer captures its config via closure). Both accept bare `Mod` and `{Mod, opts}` shapes. A parallel `normalize_plugin_entry/1` handles compile-time plugin entries during `Agent.new/1` config auto-merge (C5 spec).

### `lib/jido/plugin.ex` — **not touched in this commit**

The old `Jido.Plugin` macro stays alive through C4 so the 5 in-tree plugin files (which haven't been migrated yet) continue to compile. The plugin-hook integration with AgentServer (`handle_signal/2`, `transform_result/3` calls) is **deleted** from `agent_server.ex` in this commit — so these callbacks on plugin modules become dead code (still defined but never called). Not a compile problem; just temporarily inert.

C5 is where `Jido.Plugin`'s macro gets rewritten to `use Jido.Slice + use Jido.Middleware` alongside the in-tree plugin migrations.

## Files to create

### ~~`lib/jido/middleware/persister.ex`~~ — moved to C5

`Jido.Middleware.Persister` ships in C5 as a middleware-only module (no Slice, no agent.state footprint). Blocks on `Jido.Persist.thaw/hibernate` IO synchronously during `lifecycle.starting` / `lifecycle.stopping`, replacing `ctx.agent` with the thawed struct before calling `next`. Config lives in the middleware's `opts` arg. See task 0005 for the full module definition.

Defined in C5 at `lib/jido/middleware/persister.ex`. See task 0005 for the full module definition.

C4 ships the middleware **pipeline infrastructure** plus one middleware module: `Retry`. No error-handling middleware (LogErrors/StopOnError) — error model is deferred to a follow-up PR.

### `lib/jido/middleware/retry.ex`

```elixir
defmodule Jido.Middleware.Retry do
  use Jido.Middleware

  @moduledoc """
  Retries signals whose pipeline returns %Error{} directives. Config:

    - `:max_attempts` (default 3): total attempts including the first.
    - `:pattern` (optional): signal type pattern (same syntax as signal_routes).
      If set, only matching signals are retried. If nil, retries all signals
      that produce errors.

  Use case: flaky tool calls, transient storage errors, upstream timeouts.

  Backoff / jitter deferred to follow-up — first pass does immediate retry.
  """

  alias Jido.Signal

  def on_signal(signal, ctx, opts, next) do
    if applies?(signal, opts) do
      max = Map.get(opts, :max_attempts, 3)
      attempt(signal, ctx, next, max)
    else
      next.(signal, ctx)
    end
  end

  defp attempt(signal, ctx, next, attempts_left) when attempts_left > 0 do
    {_new_ctx, dirs} = result = next.(signal, ctx)

    if has_error?(dirs) and attempts_left > 1 do
      attempt(signal, ctx, next, attempts_left - 1)
    else
      result
    end
  end

  defp has_error?(dirs), do: Enum.any?(dirs, &match?(%Jido.Agent.Directive.Error{}, &1))

  defp applies?(_signal, %{pattern: nil}), do: true
  defp applies?(%Signal{type: type}, %{pattern: pattern}) when not is_nil(pattern),
    do: Jido.Signal.Router.matches?(pattern, type)
  defp applies?(_signal, _opts), do: true
end
```

## Files deleted

- `lib/jido/agent_server/error_policy.ex`

## Acceptance

- `mix compile --warnings-as-errors` passes
- `lib/jido/agent_server.ex` no longer calls `handle_signal/2`, `transform_result/3`, or `error_policy` logic — those are replaced by the middleware chain
- `lib/jido/agent.ex` no longer has `on_before_cmd/2` or `on_after_cmd/3` callbacks
- In-tree plugin files still define `mount/2`, `handle_signal/2`, etc. — dead code until C5 removes them. Not a compile issue.
- A scratch agent with `middleware: [{Jido.Middleware.Retry, %{max_attempts: 3}}]` receives a signal whose action fails twice then succeeds: verify it ultimately succeeds via manual IEx session (no automated test yet — that's C8).
- `mix test` — **expect failures** in:
  - `test/jido/agent_server/plugin_signal_hooks_test.exs`, `plugin_signal_middleware_test.exs`, `plugin_transform_test.exs`, `plugin_subscriptions_test.exs` — retired or rewritten in C8
  - `test/jido/agent_server/error_policy_test.exs` — retired in C8
  - `test/examples/plugins/plugin_middleware_test.exs` — rewritten in C8 to target new middleware

## Out of scope

- Migrating in-tree plugins (Thread, Identity, Memory, Pod, BusPlugin) to use the new Middleware tier (→ C5)
- Implementing Jido.Middleware.Persister (→ C5) — Plugin (Slice + Middleware) with blocking IO in the middleware half
- Anything lifecycle- or ack-related (→ C6, C7)

## In-tree plugins are functionally inert during C4

After this commit, AgentServer no longer calls `handle_signal/2`, `transform_result/3`, `on_before_cmd/2`, or `on_after_cmd/3` on plugin modules. The 5 in-tree plugins (Thread, Identity, Memory, Pod, BusPlugin) still *have* these callbacks (the old `Jido.Plugin` macro still generates them through C4) — but they're never invoked. Their signal-handling logic is **dead code for one commit's span (C4 → C5)**.

What still works between C4 and C5:
- Slice state at `agent.state[plugin.state_key]` — read/write via `StateOp` directives and `Agent.cmd/2` still work.
- Plugin child processes — `start_plugin_children` in `post_init` still fires.
- Plugin subscriptions via the old static mechanism — still registered.

What does NOT work between C4 and C5:
- Any plugin behavior encoded in `handle_signal/2` — silent no-op.
- Any behavior encoded in `transform_result/3` — silent no-op.
- `mount/2` side effects — never called (AgentServer-side call is deleted).

This is intentional per the red-tree policy (C2-C7 are red; no single-commit working state is promised). Spot-checking C4 in IEx: expect plugins to appear "present" (slice state exists) but behaviorally inert. C5 restores all plugin behaviors via the new Middleware tier in the same commit that rewrites the `Jido.Plugin` macro.

## Ctx shape contract — lock now, additive-only later

Middleware and action authors observe the ctx map through their 4-arg callbacks. The keys AgentServer seeds are a public contract.

**Base ctx (always present)**:

| Key | Type | Source | Notes |
|---|---|---|---|
| `:agent` | `Jido.Agent.t()` | `state.agent` | Mutable during chain; updated by core after `cmd/2` returns |
| `:agent_module` | `module()` | `state.agent_module` | — |
| `:agent_id` | `String.t()` | `state.id` | — |
| `:partition` | `term() \| nil` | `state.partition` | — |
| `:parent` | `%ParentRef{} \| nil` | `state.parent` | — |
| `:orphaned_from` | `%ParentRef{} \| nil` | `state.orphaned_from` | — |
| `:jido` | `atom()` | `state.jido` | Jido instance name |

**Merged from signal** (`signal.extensions[:jido_ctx]` — user-supplied):

Any keys the caller put there. Conventionally `:current_user`, `:trace_id`, `:tenant_id`, etc. Merged in via `Map.merge(base_ctx, signal_ctx)`.

**Special case — `starting` emission**:

At `lifecycle.starting` emission time (inside `init/1`, before `post_init`), ctx still has all base keys — **but**:
- `:agent` — slice state is **schema-default entering the chain**. If the Persister plugin is declared and positioned before a given middleware in the chain, Persister's middleware half blocks on thaw IO and replaces `ctx.agent` with the thawed struct before the downstream middleware sees it. So: **middleware upstream of Persister sees pre-thaw state; middleware downstream of Persister sees post-thaw state.** Chain ordering is user-declared; position Persister first if downstream middleware needs thawed state at `starting`. Middleware that doesn't want to reason about ordering observes `lifecycle.ready` (where thaw is guaranteed complete).
- `state.children` is empty; if middleware reads via `ctx.agent.state.children` it sees `%{}`
- Subscriptions not started; cron schedules not registered
- Signal router not built

Middleware observing `starting` should be explicit about whether it needs thawed state and position itself accordingly. Reading post-init-only state (children, subscription handles) still sees empty/nil.

## Telemetry scope (per S9)

**Existing events preserved verbatim.** The telemetry emission at the signal-processing boundary ([agent_server.ex:1468-1527](../../lib/jido/agent_server.ex)) continues to emit `[:jido, :agent_server, :signal, :start|:stop|:exception]` at the **outermost** boundary of the chain — the same point where the current plugin-hook pipeline emits them today. Downstream telemetry consumers see the same event names, the same metadata shape.

**No per-middleware span events in this PR.** Each individual middleware layer does NOT emit its own `:start` / `:stop` pair. This means middleware-internal behavior — retry attempts, skip fires, per-layer timings — is NOT directly observable via telemetry.

Deferred to a future observability-focused follow-up PR:
- `[:jido, :middleware, :on_signal, :start|:stop|:exception]` with `:middleware_module` metadata
- Retry-middleware-specific events (attempt count, backoff timing)
- Subscribe/ack dispatch events

## Risks

- Middleware chain composition must be deterministic. Build the chain exactly once at the top of `init/1` (per SS3) and store on `%State{}` via `State.from_options/3` — rebuilding per signal would double-execute slice-side contributions and break route registration expectations.
- The ctx shape above is a new public contract. Lock the keys now: additive later is fine; subtractive is breaking.
- `execute_directives/3` currently sits between `process_signal_common` and the telemetry/transform-hook phase. Moving it inside `core_next` requires confirming that directive failures correctly propagate as `%Error{}` directives rather than raises — test with a failing `Directive.Spawn{}`.
- The `DirectiveExec.ex:77` hardcoded-path bit (partially fixed in C2) must be verified once more against the middleware chain — actions should read state via `ctx`, never via `state.agent.state.<hardcoded>`.
- The Persister **Plugin** (C5) has a middleware half that blocks on `Jido.Persist.thaw/hibernate` IO synchronously during `lifecycle.starting` / `lifecycle.stopping`. No separate directive structs or executors. Blocking on the mailbox path is accepted because lifecycle emissions are rare and one-shot, and the alternative (post-chain executor) creates an asymmetric view where in-chain observers see pre-thaw state.
- **Same-module collisions** between compile-time `middleware:` / `plugins:` and runtime `Options.middleware:` are **not detected in this commit**. Re-evaluate when InstanceManager actually injects Persister (C5/C6); until then the chain composes whatever is declared and same-module-different-opts (e.g. two `Retry` instances) is allowed.
