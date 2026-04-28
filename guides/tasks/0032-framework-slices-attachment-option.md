---
name: Task 0032 — Framework: `slices:` option on `use Jido.Agent` for attaching configured slices
description: Add a `slices:` option to `use Jido.Agent` accepting `[Module | {Module, config}]`. Each entry must be a `use Jido.Slice` module (not a `use Jido.Plugin` module). The slice mounts at its declared `path()`, initial state is seeded from `config` validated through the slice's `config_schema/0`, signal routes from the slice are registered with their absolute paths (no plugin prefixing), and actions are aggregated. Plus rename / migrate the misnamed framework singletons (`Jido.{Identity,Memory,Thread}.Plugin`) — they are slices, not plugins. Pairs with task 0029 (which tightens `plugins:` to reject bare slices once `slices:` exists).
---

# Task 0032 — Framework: `slices:` option on `use Jido.Agent`

- Implements: ADR 0014 (the slice/plugin split, properly enforced), supports
  [ADR 0022 v3](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §6.
- Depends on: nothing.
- Pairs with: [task 0029](0029-reject-bare-slice-in-plugins.md) — once `slices:`
  exists, `plugins:` can reject bare slices without leaving users stranded.
- Blocks: [task 0030](0030-llm-agent-slice-composition-refactor.md).
- Leaves tree: **green**.

## Context

ADR 0014 splits cross-cutting capabilities into two units:

- **Slice** = state + actions + signal routes + (optional) sensors / schedules
- **Middleware** = around-each-signal hook (`on_signal/4`)
- **Plugin** = `Slice + Middleware` in one module (`use Jido.Plugin` expands to
  `use Jido.Slice` + `use Jido.Middleware`)

The `use Jido.Agent` macro today exposes:

- `path:` / `schema:` / `signal_routes:` — the agent's **own** slice.
- `plugins: [Module | {Module, config}]` — modules implementing the
  `plugin_spec/1` contract.
- `default_plugins:` — framework-default singletons, override-only via a map.
- `middleware: [Module | {Module, opts}]` — bare middleware modules.

There is no clean way to attach a **bare slice** with config to a non-AI agent.
Today users have three workarounds, all wrong:

1. Stuff the slice into `plugins:`. Compiles because
   `__validate_plugin_module__/1` only checks for `plugin_spec/1`, which both
   `use Jido.Slice` and `use Jido.Plugin` provide. Wrong because the slice has
   no middleware half — task 0029 disallows this once `slices:` exists.
2. Make the slice the agent's *own* slice via `path:`/`schema:`/`signal_routes:`.
   Works for one slice. Doesn't compose if the agent already has its own slice
   for something else (e.g. a chat agent that wants AI capability layered on).
3. Inline the slice's metadata into the agent's macro. Forces every agent that
   uses the slice to re-declare its `path`/`schema`/`signal_routes` and bake
   slice-config into the agent's compile-time options. Both v1 and v2 of
   ADR 0022 hit this and concluded it's the wrong shape — the slice should
   attach itself.

Compounding the muddle, the framework's own singletons —
`Jido.Identity.Plugin`, `Jido.Memory.Plugin`, `Jido.Thread.Plugin` — are
`use Jido.Slice` (bare slices), not `use Jido.Plugin`. They are named "Plugin"
because they ride the `default_plugins:` machinery, but they are slices.
That's a lie in the type system; this task clears it up.

## Goal

After this commit:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent,
    name: "support",
    slices: [
      {Jido.AI.ReAct,
        model: "anthropic:claude-haiku-4-5-20251001",
        tools: [MyApp.Actions.LookupOrder],
        system_prompt: "You are a support agent.",
        max_iterations: 5}
    ]
end
```

The agent declares **no LLM concepts**. The slice attaches itself with config.
The slice's `path/0`, `schema/0` (or, after task 0030, `schema/1` consumed
through `config_schema/0`), `actions/0`, and `signal_routes/0` are all read
off the slice module — the agent does not duplicate them.

Multiple slices compose:

```elixir
use Jido.Agent,
  name: "support",
  slices: [
    Jido.Memory.Slice,                 # a renamed framework singleton
    {Jido.AI.ReAct, model: "...", tools: [...]},
    {MyApp.AnalyticsSlice, sample_rate: 0.1}
  ]
```

Each slice mounts at its own `path()`. Path collisions across the agent's own
`path:`, `slices:`, and `default_plugins:` raise `CompileError` at the agent
module's compile time.

## Files to modify

### `lib/jido/agent.ex`

1. Add `slices:` to `@agent_config_schema`:

   ```elixir
   slices:
     Zoi.list(Zoi.any(),
       description: "Bare slice modules or {Module, config} tuples"
     )
     |> Zoi.default([])
   ```

2. In `__using__/1`'s compile-time setup, parse `@validated_opts[:slices]`:

   - Normalize each entry to `{Module, config_keyword_or_map}`.
   - Validate the module is a `Jido.Slice` — `function_exported?(mod,
     :__jido_slice__, 0)` (a marker injected by `use Jido.Slice` per the
     companion change below). Modules that are *also* `use Jido.Plugin` are
     rejected here (they belong in `plugins:` — see task 0029).
   - Build a `Jido.Slice.Instance` (parallel to `Jido.Plugin.Instance`)
     carrying the resolved config and the module's manifest.

3. Aggregate paths, actions, and signal routes from `slices:` alongside the
   existing aggregations from `plugins:` / `path:` /
   `signal_routes:`. Emit the same compile-time error on duplicate paths.

4. In `__build_initial_state__/1`, seed each `slices:` instance the same way
   `plugin_slices` are seeded — `__seed_plugin_slice__/2` (or rename to
   `__seed_slice__/2`) called against `(instance.config + user_state[path])`,
   validated through the slice's `config_schema/0` if present.

5. Routes from `slices:` instances expand with **no prefix** — the slice's
   `signal_routes/0` are absolute paths. (This is different from `plugins:`
   where the plugin's name prefixes routes via `Jido.Plugin.Routes.expand_routes/1`.
   Bare slices don't get the prefix because they aren't aliased — there's
   nothing to multi-instance.)

### `lib/jido/slice.ex`

Inject a `__jido_slice__/0` marker function from `use Jido.Slice`:

```elixir
@doc false
@spec __jido_slice__() :: true
def __jido_slice__, do: true
```

This is the type-system marker the agent's `slices:` validator uses to
distinguish "a real slice" from "a module that happened to define
`plugin_spec/1`."

### `lib/jido/plugin.ex`

Inject a `__jido_plugin__/0` marker (parallel to the slice marker) so
`plugins:` validation can require `use Jido.Plugin` (task 0029's fix). A
module that is `use Jido.Plugin` has *both* markers — `__jido_slice__/0`
(from the inner `use Jido.Slice`) and `__jido_plugin__/0` (from the outer
`use Jido.Plugin`). The two validators distinguish:

- `slices:` requires `__jido_slice__/0` and **rejects** modules that *also*
  have `__jido_plugin__/0`. Plugins go in `plugins:`.
- `plugins:` requires `__jido_plugin__/0` (per task 0029).

### `lib/jido/identity/plugin.ex`, `lib/jido/memory/plugin.ex`, `lib/jido/thread/plugin.ex`

These modules are `use Jido.Slice` named "Plugin." Rename and migrate:

- `Jido.Identity.Plugin` → `Jido.Identity.Slice`
- `Jido.Memory.Plugin` → `Jido.Memory.Slice`
- `Jido.Thread.Plugin` → `Jido.Thread.Slice`

Update every reference in `lib/`, `test/`, and `guides/`. The framework's
default-plugins machinery (`Jido.Agent.DefaultPlugins`) feeds these into the
new `slices:` attachment path — they are no longer attached via `plugins:`.

### `lib/jido/agent/default_plugins.ex`

Rename module to `Jido.Agent.DefaultSlices`. Rename every public function from
`plugin`-named to `slice`-named (e.g., `package_defaults/0` keeps its name;
`apply_agent_overrides/2` keeps its name). The framework's "default plugins"
were always slices; the rename brings names and types into alignment.

The agent macro option `default_plugins:` keeps its name as a deprecation
shim *only* if needed for migration (suggest: keep the option, redirect to
`default_slices:` internally, leave both names accepting the same shape, with
`default_plugins:` documented as the legacy alias). Decide during
implementation; the cheap path is "rename without alias" since this is a
pre-1.0 framework and no out-of-tree consumers exist.

## Files to create

### `lib/jido/slice/instance.ex`

Parallel to `Jido.Plugin.Instance`. A struct carrying:

- `:module` — the slice module
- `:as` — optional alias for multi-instance scenarios (out of scope for v1;
  reserve the field, default `nil`)
- `:config` — resolved config map (filtered through `config_schema/0` when
  present)
- `:manifest` — `module.manifest()`
- `:path` — `module.path()` (or, if multi-instance ever lands, derived)

`Jido.Slice.Instance.new/1` accepts `Module` or `{Module, config}` and returns
the validated struct. Mirrors `Jido.Plugin.Instance.new/1` but does NOT compute
a `route_prefix` — bare slices don't prefix their routes.

### `test/jido/agent/slices_attachment_test.exs`

Cover:

1. `use Jido.Agent, slices: [SomeSlice]` mounts the slice at its `path()`
   with seeded defaults.
2. `use Jido.Agent, slices: [{SomeSlice, key: value}]` seeds the config into
   the slice's initial state.
3. The slice's signal_routes register at the agent with absolute paths (no
   prefixing).
4. Path collision between `path:` and a `slices:` entry raises CompileError.
5. Path collision between two `slices:` entries raises CompileError.
6. Putting a `use Jido.Plugin` module in `slices:` raises CompileError with a
   clear message ("plugins go in `plugins:`, not `slices:`").
7. Putting a non-slice module (no `__jido_slice__/0`) in `slices:` raises.
8. The renamed `Jido.{Identity,Memory,Thread}.Slice` modules attach via the
   default-slices path.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean — zero `warning:` lines (the existing default-plugins tests
  may need their references renamed; that's part of this task).
- `mix test --include e2e` clean — zero `warning:` lines.
- A regression test demonstrates the misuse from ADR 0022 v1 (a bare slice in
  `plugins:`) now raises with a clear "use `slices:` instead" message — the
  combined effect of task 0029 + this task.

## Out of scope

- Multi-instance slices (`{Slice, as: :customer_chat, ...}`). Reserve the field
  in `Slice.Instance` but don't wire it. The plugin machinery already supports
  this via `Plugin.Instance.derive_path/2` and `derive_route_prefix/2`; the
  slice path is harder because bare slices don't have a `route_prefix` concept.
  Address only when a concrete need surfaces.

- A migration shim for out-of-tree consumers of `Jido.{Identity,Memory,Thread}.Plugin`.
  No such consumers exist in the codebase; if any external user depends on the
  old name we'll add an alias in a later task.

- Touching the `plugins:` machinery beyond the marker function. Task 0029
  ships the actual rejection; this task ships the marker so 0029 has something
  to check against.

## Risks

- **Surface area.** Renaming the framework's default singletons touches many
  files (every test that mocks an agent, every docs reference, every guide).
  The rename is mechanical (regex-replace) but the line count of the diff is
  large. Run `mix test` between the slice/plugin code change and the rename
  to isolate failures from each.

- **`default_plugins:` option name.** Users (including livebooks and the test
  suite) reference this option. The cheapest path is to rename to
  `default_slices:` and update every call site. The user-facing option is
  pre-1.0; rename without an alias.

- **`use Jido.Plugin` modules attached today.** Any in-tree `use Jido.Plugin`
  module continues to be attached via `plugins:`. The rename only touches
  framework singletons that were misnamed. Confirm with `grep -rln "use
  Jido.Plugin"` before renaming so we don't accidentally rename a real plugin.

- **Compile-time validation message clarity.** When the framework rejects a
  `use Jido.Plugin` module in `slices:`, the error must point at the right
  bucket. Use a message like:

  > `MyApp.AuditPlugin` is a Plugin (`use Jido.Plugin`). Plugins go in
  > `plugins:`; `slices:` is for bare `use Jido.Slice` modules. Move it to
  > `plugins:` or change the module to `use Jido.Slice`.

- **Order of work with task 0029.** Task 0029 needs the `__jido_plugin__/0`
  marker to do its check; this task ships that marker. So 0032 must land
  before (or in the same commit as) 0029. The cleanest sequencing:
  this task adds both markers and the `slices:` machinery; task 0029 is then
  a small follow-up that flips `__validate_plugin_behaviour__/1` to require
  the plugin marker and updates its error message.
