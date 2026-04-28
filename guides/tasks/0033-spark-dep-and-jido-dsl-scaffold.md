---
name: Task 0033 — Add `:spark` dep + scaffold `Jido.Dsl.*` namespace
description: Add `{:spark, "~> 2.2"}` as a runtime dep of jido, create the `lib/jido/dsl/` directory with empty placeholder modules (`Jido.Dsl.Agent`, `Jido.Dsl.Slice`, `Jido.Dsl.Plugin`, `Jido.Dsl.Middleware`, `Jido.Dsl.Action`, `Jido.Dsl.Sensor`, `Jido.Dsl.Instance`), and wire `mix spark.formatter` so subsequent tasks have somewhere to land their section definitions. No public surface changes; the tree stays green.
---

# Task 0033 — `:spark` dep + `Jido.Dsl.*` scaffold

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1.
- Depends on: nothing.
- Blocks: [task 0034](0034-port-jido-agent-to-spark.md), [task 0035](0035-port-slice-plugin-middleware-to-spark.md), [task 0036](0036-port-action-and-sensor-to-spark.md), [task 0037](0037-extensions-contribute-dsl-sections.md), [task 0038](0038-docs-and-cleanup.md).
- Leaves tree: **green**.

## Context

ADR 0023 calls for migrating every `use Jido.X` site to a Spark DSL
and exposing slices / plugins / middleware as Spark extensions. Before
any of the surface migrations land, we need:

1. The `:spark` dep available to compile against.
2. A home for the DSL definitions (`lib/jido/dsl/`).
3. The Spark formatter task wired so the per-DSL `.formatter.exs`
   entries can be generated and committed by later tasks.

This commit ships those affordances and nothing else. No `use Jido.X`
site is touched; existing code keeps compiling against its current
hand-rolled macro.

## Files to modify

### `mix.exs`

Add `:spark` to `deps/0`:

```elixir
{:spark, "~> 2.2"}
```

Place it after `:nimble_options` (or wherever the alphabetic order
lands) so the diff is small. Confirm `mix.lock` regenerates cleanly.

### `.formatter.exs`

Add Spark's import_deps + plugin entries:

```elixir
[
  import_deps: [:spark],
  plugins: [Spark.Formatter],
  inputs: [...existing inputs...]
]
```

If `import_deps:` already exists, append `:spark`; otherwise add the
key. Same for `plugins:`.

### `mix.lock`

Regenerate via `mix deps.get`; commit the lockfile diff.

## Files to create

### `lib/jido/dsl/agent.ex`

```elixir
defmodule Jido.Dsl.Agent do
  @moduledoc """
  Spark DSL extension for `Jido.Agent`.

  See `Jido.Agent` for the public surface. Section / entity
  definitions land here in [task 0034](
  ../../guides/tasks/0034-port-jido-agent-to-spark.md).
  """

  use Spark.Dsl.Extension, sections: []
end
```

### `lib/jido/dsl/slice.ex`

```elixir
defmodule Jido.Dsl.Slice do
  @moduledoc """
  Spark DSL extension for `Jido.Slice`. Section / entity definitions
  land here in [task 0035](../../guides/tasks/0035-port-slice-plugin-middleware-to-spark.md).
  """

  use Spark.Dsl.Extension, sections: []
end
```

### `lib/jido/dsl/plugin.ex`

```elixir
defmodule Jido.Dsl.Plugin do
  @moduledoc "Spark DSL extension for `Jido.Plugin`. Filled in by task 0035."

  use Spark.Dsl.Extension, sections: []
end
```

### `lib/jido/dsl/middleware.ex`

```elixir
defmodule Jido.Dsl.Middleware do
  @moduledoc "Spark DSL extension for `Jido.Middleware`. Filled in by task 0035."

  use Spark.Dsl.Extension, sections: []
end
```

### `lib/jido/dsl/action.ex`

```elixir
defmodule Jido.Dsl.Action do
  @moduledoc "Spark DSL extension for `Jido.Action`. Filled in by task 0036."

  use Spark.Dsl.Extension, sections: []
end
```

### `lib/jido/dsl/sensor.ex`

```elixir
defmodule Jido.Dsl.Sensor do
  @moduledoc "Spark DSL extension for `Jido.Sensor`. Filled in by task 0036."

  use Spark.Dsl.Extension, sections: []
end
```

### `lib/jido/dsl/instance.ex`

```elixir
defmodule Jido.Dsl.Instance do
  @moduledoc """
  Spark DSL extension for `use Jido` (the application instance
  supervisor). Filled in by task 0034 (instance migrates with the
  agent surface).
  """

  use Spark.Dsl.Extension, sections: []
end
```

### `test/jido/dsl/scaffold_test.exs`

A trivial test that confirms each scaffold module compiles and reports
itself as a Spark DSL extension:

```elixir
defmodule Jido.Dsl.ScaffoldTest do
  use ExUnit.Case, async: true

  for module <- [
        Jido.Dsl.Agent,
        Jido.Dsl.Slice,
        Jido.Dsl.Plugin,
        Jido.Dsl.Middleware,
        Jido.Dsl.Action,
        Jido.Dsl.Sensor,
        Jido.Dsl.Instance
      ] do
    test "#{inspect(module)} is a Spark.Dsl.Extension" do
      assert Spark.implements_behaviour?(unquote(module), Spark.Dsl.Extension)
    end

    test "#{inspect(module)} has an empty section list (filled by later tasks)" do
      assert unquote(module).sections() == []
    end
  end
end
```

## Acceptance

- `mix deps.get` clean; `mix.lock` updated.
- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean (the new files plus the
  updated `.formatter.exs`).
- `mix credo --strict` clean.
- `mix test` clean — zero `warning:` lines.
- `mix test --include e2e` clean — zero `warning:` lines.
- The new `test/jido/dsl/scaffold_test.exs` passes.

## Out of scope

- Touching any existing `use Jido.X` site. That's tasks 0034–0036.
- Filling in section / entity definitions. Each later task fills in
  the DSL for its surface.
- `mix spark.formatter` regeneration. Per-section `.formatter.exs`
  entries are added in tasks 0034–0036 as those sections come online.
- Generating cheat sheets (`mix spark.cheat_sheets`). Task 0038.

## Risks

- **Spark version pin.** `~> 2.2` matches Ash 3.x. Confirm at
  implementation time that the latest 2.x line is selected; bump to
  the latest minor if needed.
- **Formatter plugin order.** Spark's formatter plugin must come
  before any project-specific plugin. Run `mix format` against the
  full tree as a sanity check after the dep lands.
- **Igniter overlap.** `lib/jido/igniter/` already exists; we are not
  touching it here. Spark and Igniter coexist (Spark depends on
  Igniter); the dep tree resolves cleanly.
