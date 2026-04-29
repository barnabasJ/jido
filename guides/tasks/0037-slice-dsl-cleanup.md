---
name: Task 0037 — Slice DSL cleanup: drop redundant `actions do` block, drop `singleton:`
description: Two small, focused refactors of `Jido.Dsl.Slice`. (1) Drop the `actions do … end` section: every in-tree slice already lists each routed action twice (once in `actions`, once as the `action:` field of a `route` in `signal_routes`), and the `actions/0` accessor can be derived from `signal_routes/0` as `Enum.uniq(routes |> Enum.map(& &1.action))`. (2) Drop the `singleton:` field on the slice section: it exists only to gate `Plugin.Instance` from accepting an `as:` alias and to validate the pod-plugin replacement contract — both can move to alternate signals (path equality for the pod plugin, plain "no `as:` if path is already taken" for the alias case). After this commit a slice declares **shape + routes + capabilities + requires + (optional) subscriptions / schedules / config_schema** and nothing else; the accessor surface tightens correspondingly.
---

# Task 0037 — Slice DSL cleanup

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 §4 — slice surface tightening that pairs with the contribution mechanism in [task 0040](0040-extensions-contribute-dsl-sections.md).
- Depends on: [task 0036](0036-port-action-and-sensor-to-spark.md) (slice DSL is on Spark).
- Blocks: [task 0038](0038-slices-must-declare-schema-and-routes.md), [task 0040](0040-extensions-contribute-dsl-sections.md).
- Leaves tree: **green**.

## Context

After task 0035 every slice declares two parallel registries that
say nearly the same thing:

```elixir
actions do
  action Actions.Ask
  action Actions.LLMTurn
  action Actions.ToolResult
  action Actions.Failed
end

signal_routes do
  route "ai.react.ask",            Actions.Ask
  route "ai.react.llm.completed",  Actions.LLMTurn
  route "ai.react.tool.completed", Actions.ToolResult
  route "ai.react.failed",         Actions.Failed
end
```

Every action shows up in both lists — the second one as a route
target, the first one as a bare ownership claim. The `actions do`
block exists only so `actions/0` and the `manifest.actions` field
have a backing list, but the same list is reachable from
`signal_routes`'s `action:` fields with `Enum.uniq`. Whenever a
slice routes every action it owns (the universal case in tree —
`Jido.AI.ReAct`, `Jido.Pod.Plugin`, `Jido.Pod.BusPlugin`), the
`actions do` block is pure duplication.

The `singleton:` field on the `slice do` section is the second
wart: it carries through to `manifest.singleton` and gates two
specific decisions:

1. **`Jido.Plugin.Instance.new/1`** rejects an `as:` alias on a
   singleton plugin (e.g. `{Jido.Pod.Plugin, as: :extra}` raises).
   Defended at [plugin/instance.ex:84-87](../../lib/jido/plugin/instance.ex).
2. **`Jido.Pod.Definition.split_pod_plugins!/2`** requires that a
   user-supplied custom pod plugin (replacing `Jido.Pod.Plugin`) be
   declared `singleton: true`. Defended at
   [pod/definition.ex:137-147](../../lib/jido/pod/definition.ex).

Both checks are reachable through other invariants:

- The first reduces to "two slices can't share a path" — the
  existing `Jido.Dsl.Agent.Verifiers.UniquePaths` already enforces
  it. If both `Jido.Pod.Plugin` and `{Jido.Pod.Plugin, as: :extra}`
  resolved to `:pod`, they'd conflict at `UniquePaths`. The `as:`
  alias derives a different path (`:pod_extra`), but if the user
  *wants* the alias, why are we stopping them? The "singleton plugin
  cannot be aliased" rule was a 2025-era safety belt that no longer
  earns its complexity.
- The second reduces to "the replacement plugin's path is `:pod`
  and it advertises capability `:pod`". That's already the
  pod-plugin contract; the singleton check is orthogonal noise.

After this commit, a slice's surface is exactly:

```elixir
slice do
  name        # required
  path        # required
  description # optional
  category    # optional
  vsn         # optional
  otp_app     # optional
  schema      # optional (Zoi schema for slice state)
  config_schema # optional (Zoi schema for per-agent config)
  tags        # optional
end

signal_routes do … end
subscriptions do … end
schedules do … end
capabilities do … end
requires do … end
```

No `actions do … end`. No `singleton: …`.

## Goal

After this commit the duplication is gone:

```elixir
defmodule Jido.AI.ReAct do
  use Jido.Slice

  slice do
    name "react"
    path :ai
    description "ReAct reasoning slice over ReqLLM."
    schema Jido.AI.ReAct.State.schema()
    config_schema Jido.AI.ReAct.Config.schema()
  end

  signal_routes do
    route "ai.react.ask",            Actions.Ask
    route "ai.react.llm.completed",  Actions.LLMTurn
    route "ai.react.tool.completed", Actions.ToolResult
    route "ai.react.failed",         Actions.Failed
  end
end
```

`Jido.AI.ReAct.actions/0` returns `[Actions.Ask, Actions.LLMTurn,
Actions.ToolResult, Actions.Failed]` — derived from
`signal_routes/0` at compile time by the slice's accessor
generator.

`Jido.Pod.Plugin` and `Jido.Pod.BusPlugin` lose their
`singleton true` line; the plugin-instance alias check and the
pod-plugin replacement check switch to path-based signals.

## Files to modify

### `lib/jido/dsl/slice.ex`

1. Remove the `@actions_section` definition and drop it from the
   `sections:` list passed to `use Spark.Dsl.Extension`.
2. Remove `singleton: [type: :boolean, default: false]` from the
   `@slice_section` schema.
3. Strip the `actions do … end` and `singleton:` mentions from the
   moduledoc.

### `lib/jido/slice/action_entry.ex`

Delete. It's the target struct for the deleted `action` entity and
has no other consumers (`grep ActionEntry` currently surfaces only
the slice DSL definition and one test scaffold reference).

### `lib/jido/dsl/slice/transformers/generate_accessors.ex`

1. Replace the `actions:` reader (currently
   `Spark.Dsl.Extension.get_entities(dsl_state, [:actions]) |>
   Enum.map(& &1.module)`) with a derived value:

   ```elixir
   actions =
     dsl_state
     |> Spark.Dsl.Extension.get_entities([:signal_routes])
     |> Enum.map(& &1.action)
     |> Enum.filter(&is_atom/1)   # drop {Module, fun, args} mfa shapes for now
     |> Enum.uniq()
   ```

2. Drop the `singleton:` reader and the `@jido_slice_singleton`
   module attribute.
3. Drop the `singleton?/0` accessor from the emitted body.
4. Drop `singleton?: 0` from the `defoverridable` block.
5. Remove the `__plugin_metadata__/0` and `manifest/0` body's
   `singleton:` field.

### `lib/jido/plugin/manifest.ex`

Remove the `singleton:` field from the manifest struct's Zoi
schema. Anything reading `manifest.singleton` migrates to a
different invariant (see the two callers below).

### `lib/jido/plugin/instance.ex`

Drop the singleton check at lines 84–87. The remaining behaviour:
`as:` derives a new `path` via `derive_path/2`, and
`Jido.Dsl.Agent.Verifiers.UniquePaths` rejects collisions.

### `lib/jido/pod/definition.ex`

The `validate_pod_plugin_decl!/2` function at lines 103–160
currently checks three invariants on a user-supplied pod plugin:
`singleton`, `path == :pod`, `capability :pod`. Drop the singleton
check; keep the path and capability checks. Update the error
message accordingly.

### Every in-tree slice

Drop the `actions do … end` block from each slice. Where a slice
has an unrouted action (none today, but if any surface), it must
either gain a route or move to a non-slice module. List of files
to update:

- `lib/jido/ai/re_act.ex`
- `lib/jido/identity/slice.ex`
- `lib/jido/memory/slice.ex`
- `lib/jido/thread/slice.ex`
- `lib/jido/pod/plugin.ex` (drop both `actions do` and `singleton true`)
- `lib/jido/pod/bus_plugin.ex` (drop `actions do`; if it uses
  `singleton`, drop that too)

Audit fixture / scaffold modules under `test/` — every one of
them that currently uses `actions do` or `singleton true` needs the
same edit.

### Tests

1. Per-DSL slice tests:
   - `test/jido/dsl/slice_test.exs` — drop assertions about the
     `actions/0` accessor backed by an explicit `actions do` block;
     replace with assertions that derive from a `signal_routes do`
     block. Remove `singleton?/0` assertions (the accessor is gone).
2. Slice-author plugin tests:
   - `test/jido/plugin/plugin_test.exs` — drop singleton-plugin
     fixtures or rewrite to test the new "alias requires unique
     path" invariant.
3. Pod tests:
   - `test/jido/pod_test.exs` — `CustomPodPlugin` no longer needs
     `singleton true`; the replacement contract is path + capability.
   - The "disabling the reserved pod plugin raises at compile time"
     test stays; the error message changes (no longer mentions
     "must be a singleton plugin").
4. Default-slices tests:
   - `test/jido/agent/default_slices_test.exs` — assertions that
     hit `manifest.singleton` need to change shape; replace with
     equivalent checks against `manifest.path`.

## Acceptance

- `mix compile --warnings-as-errors` clean for `lib/`.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean (the FULL suite — no exclusions).
- `mix test --include e2e` clean.

The new shape:

```
git grep -nE "actions do$|singleton[[:space:]]+true|singleton:" lib/
```

returns zero hits in `lib/`. The slice DSL surface is the smaller
list documented in the moduledoc.

## Out of scope

- **Promoting key-reservation slices to real slices.** That work
  lands in [task 0038](0038-slices-must-declare-schema-and-routes.md) —
  the three default slices (Memory / Identity / Thread) gain
  schemas, routed actions, and (optionally) config schemas there.
  This task only drops the redundant `actions do` and `singleton:`
  surface.
- **Replacing `__plugin_metadata__/0`** with Spark introspection:
  [task 0039](0039-replace-metadata-callbacks-with-spark-introspection.md).
- **The contribution mechanism** (`use Jido.Slice.Extension`,
  `extensions: [Jido.AI.ReAct]` unlocking `react do … end`):
  [task 0040](0040-extensions-contribute-dsl-sections.md).

## Risks

- **`actions/0` semantic shift.** A slice that currently lists an
  action in `actions do` but never routes it would lose that action
  from `actions/0`'s output. Audit before deleting; in tree no
  slice has an unrouted action, so this is a no-op. If a fixture
  surfaces, either route it or remove it.
- **Manifest readers.** Anything that reads `manifest.singleton`
  needs migration. `git grep "manifest.singleton" lib/ test/` should
  surface them all; rewrite each to the appropriate path-based
  check.
- **`as:` alias on framework slices.** With the singleton gate
  gone, a user could now write `{Jido.Memory.Slice, as: :short_term}`
  and get a slice mounted at `:memory_short_term`. The
  `UniquePaths` verifier still catches the same-path case. Decide
  intentionally whether the alias path-mangling is the right
  ergonomics — task 0040 introduces typed-block `path :…` overrides
  which is the cleaner spelling.
