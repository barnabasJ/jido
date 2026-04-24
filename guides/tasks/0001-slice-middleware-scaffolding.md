# Task 0001 — Slice / Middleware scaffolding

- Commit #: 1 of 9
- Implements: [ADR 0014](../adr/0014-slice-middleware-plugin.md) — structural scaffolding only
- Depends on: **0000** (action inlined, `run/4` signature in place, ctx threading)
- Blocks: 0002, 0004, 0005
- Leaves tree: **green** (purely additive)

## Goal

Introduce `Jido.Slice` and `Jido.Middleware` as first-class modules. **`Jido.Plugin` is left untouched** — the rewrite into the `use Jido.Slice + use Jido.Middleware` combo happens in C5 paired with the in-tree plugin file migrations. This means no temporary Legacy shim and no annotations on existing plugin files in this commit.

After this task: the new abstractions exist and are usable by any new code; existing in-tree plugins and `Jido.Plugin` still work exactly as they do today. Tree is green.

## Files to create

### `lib/jido/slice.ex`

`defmacro __using__(opts)` over these declarative fields only (validated via Zoi at compile time):

- `name` — string, required, validated by `Jido.Util.validate_name/2`
- `path` — atom, required (the flat slice key in `agent.state`)
- `schema` — optional Zoi shape for slice state
- `config_schema` — optional Zoi shape for compile-time options
- `actions` — optional `[module()]`, validated via `Jido.Util.validate_actions/2`
- `signal_routes` — optional, static `{signal_type, {action, opts}}` list
- `subscriptions` — optional, static sensor subscription declarations (shape: `[{sensor_module, config}]` — sensors produce signals that flow into agent signal processing)
- `schedules` — optional, static cron specs (shape: `[{cron_expr :: String.t(), action_module}]` — dispatches the named action at the given cadence)

For `subscriptions:` and `schedules:`, mirror the existing `Jido.Plugin` macro's permissive Zoi validation: `Zoi.list(Zoi.any()) |> Zoi.default([])` with a doc-string describing the expected shape. Tightening to concrete typed schemas is deferred — no functional difference in C1, and individual plugin migrations in C5 can refine as needed per consumer.
- `capabilities` — optional `[atom()]`
- `requires` — optional dependency list (`{:config, :token}`, `{:plugin, :http}`, etc.)
- `description`, `category`, `vsn`, `otp_app`, `tags`, `singleton` — carried over from existing `Jido.Plugin` config for parity

Emits compile-time accessors (mirroring `Jido.Plugin` style at [lib/jido/plugin.ex:446-535](../../lib/jido/plugin.ex)):

- `name/0`, `path/0`, `schema/0`, `config_schema/0`, `actions/0`, `signal_routes/0`, `subscriptions/0`, `schedules/0`, `capabilities/0`, `requires/0`, `description/0`, `category/0`, `vsn/0`, `otp_app/0`, `tags/0`, `singleton?/0`
- `manifest/0` — returns `Jido.Plugin.Manifest.t()` (shared struct)
- `plugin_spec/1` — returns `Jido.Plugin.Spec.t()` (shared struct, `state_key` field populated from `path` for back-compat)
- `__plugin_metadata__/0` for Discovery

Explicitly **no** `@callback` declarations. No `mount/2`. No `on_checkpoint/2` / `on_restore/2`. No `handle_signal/2` / `transform_result/3`. No `child_spec/1` (covered by Slice `subscriptions:` and external supervision). A Slice is what its `use` block declares; there are no methods to override.

### `lib/jido/middleware.ex`

```elixir
defmodule Jido.Middleware do
  @callback on_signal(
              signal :: Jido.Signal.t(),
              ctx :: map(),
              opts :: map(),
              next :: (Jido.Signal.t(), map() -> {map(), [struct()]})
            ) :: {map(), [struct()]}

  @optional_callbacks on_signal: 4

  defmacro __using__(_opts) do
    quote do
      @behaviour Jido.Middleware
    end
  end
end
```

**Four args**:
- `signal` — the triggering `Jido.Signal.t()`
- `ctx` — per-signal runtime context (user, trace, agent-level identity); see C0's ctx threading decision
- `opts` — compile-time options from registration: `middleware: [{Persister, %{transforms: ...}}]` → `opts = %{transforms: ...}`. Bare module → `opts = %{}`.
- `next` — continuation function; middleware calls `next.(sig, ctx)` to proceed down the chain

Chain builder closes over each middleware's `opts` at construction time:

```elixir
# During chain construction (at init/1 top, per SS3 resolution):
fn sig, ctx, next ->
  MyMiddleware.on_signal(sig, ctx, mw_opts, next)
end
```

No other behaviour callbacks. Middleware is single-tier; everything wraps around the `next` call.

### `lib/jido/plugin.ex` — **not touched in this commit**

Leave `Jido.Plugin` exactly as it is today. It keeps generating its old callback surface (`mount/2`, `handle_signal/2`, `transform_result/3`, `on_checkpoint/2`, `on_restore/2`, etc.) and accepting `state_key:` in options. This is what lets the 5 in-tree plugins (Thread, Identity, Memory, Pod, BusPlugin) continue to compile and function through C2, C3, and C4 without any changes.

The rewrite to `use Jido.Plugin = use Jido.Slice + use Jido.Middleware` lands in **C5**, paired with the in-tree plugin file migrations in the same commit. No Legacy shim needed — the old macro stays alive until the moment its callers migrate.

## Files to modify

### `lib/jido/plugin/manifest.ex`, `lib/jido/plugin/spec.ex`, `lib/jido/plugin/instance.ex`

Add a typed `path` field alongside the existing `state_key` field. Both are populated from the same source (when a plugin declares a `state_key:` in its options, the `path` defaults to the same atom). New code added in later commits can prefer reading `path`; old code continues reading `state_key`. The redundancy collapses in C5.

No other semantic changes — just widening the struct for the transition.

### In-tree plugin files — **not touched in this commit**

[lib/jido/thread/plugin.ex](../../lib/jido/thread/plugin.ex), [lib/jido/identity/plugin.ex](../../lib/jido/identity/plugin.ex), [lib/jido/memory/plugin.ex](../../lib/jido/memory/plugin.ex), [lib/jido/pod/plugin.ex](../../lib/jido/pod/plugin.ex), [lib/jido/pod/bus_plugin.ex](../../lib/jido/pod/bus_plugin.ex) — all untouched. They compile and function exactly as today because `Jido.Plugin`'s macro is unchanged in this commit.

## Files not touched

- `lib/jido/plugin.ex` — stays as-is; rewritten in C5
- `lib/jido/agent.ex`
- `lib/jido/agent_server.ex`
- `lib/jido/agent/strategy/*.ex`
- `lib/jido/persist.ex`
- All existing in-tree plugin files
- Anything test-related

## Acceptance

- `mix compile --warnings-as-errors` passes
- `mix test` still green (no test changes yet)
- `Jido.Slice` and `Jido.Middleware` usable in a scratch module without errors
- `use Jido.Plugin, ...` still works with old semantics (state_key:, mount/2, etc.) exactly as before this commit
- In-tree plugins compile unchanged

## Out of scope

- Rewriting `Jido.Plugin` macro (→ C5, paired with in-tree plugin migrations)
- Actually using middleware in the AgentServer signal pipeline (→ C4)
- Removing any existing callback or field (→ C5)
- Renaming `state_key` to `path` at call sites (→ C2 for agent; C5 for plugins)
