---
name: Task 0036 — Port `use Jido.Action` and `use Jido.Sensor` to Spark DSL
description: Replace the `Jido.Action` and `Jido.Sensor` `__using__` macros with Spark DSL definitions in `Jido.Dsl.Action` and `Jido.Dsl.Sensor`. Action's DSL covers its current Zoi `@action_config_schema` (`name`, `description`, `category`, `tags`, `vsn`, `path`, `compensation`, `schema`, `output_schema`). Sensor's DSL covers its current option set. Every in-tree action / sensor module rewrites; tree returns to **green** at the end of this commit because actions, slices, plugins, middleware, and agents are now consistently DSL-based.
---

# Task 0036 — Port action and sensor surfaces to Spark DSL

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1.
- Depends on: [task 0035](0035-port-slice-plugin-middleware-to-spark.md).
- Blocks: [task 0037](0037-extensions-contribute-dsl-sections.md), [task 0038](0038-docs-and-cleanup.md).
- Leaves tree: **green**.

## Context

Two surfaces remain on the legacy macro after task 0035:

- `lib/jido/action.ex` — the `@action_config_schema` Zoi schema is
  large (`name`, `description`, `category`, `tags`, `vsn`, `path`,
  `compensation`, `schema`, `output_schema`), and the `__using__/1`
  body emits `name/0`, `description/0`, `category/0`, `tags/0`,
  `vsn/0`, `path/0`, `schema/0`, `output_schema/0`, and a
  `__action_metadata__/0` block. Spark structures all of this
  cleanly.
- `lib/jido/sensor.ex` — smaller surface but the same shape: an
  options keyword list parsed at compile time, validated, and
  emitted as accessor functions plus a behaviour declaration.

ADR 0023 §1 says *every* `use Jido.X` site migrates. This task
finishes the run.

## Goal

After this commit:

```elixir
defmodule Counter.Increment do
  use Jido.Action

  action do
    name "increment"
    description "Increment the counter slice."
    path :counter
    schema [by: [type: :integer, default: 1]]
  end

  @impl true
  def run(%Jido.Signal{data: %{by: by}}, slice, _opts, _ctx) do
    {:ok, %{slice | count: (slice[:count] || 0) + by}, []}
  end
end
```

```elixir
defmodule MyApp.MetricSensor do
  use Jido.Sensor

  sensor do
    name "metric_sensor"
    description "Monitors a specific metric."
    schema Zoi.object(%{metric: Zoi.string()})
  end

  @impl true
  def init(config, _context) do
    {:ok, %{metric: config.metric, last_value: nil}}
  end

  @impl true
  def handle_event({:metric_update, value}, state) do
    signal = Jido.Signal.new!(%{type: "metric.updated", data: %{value: value}})
    {:ok, %{state | last_value: value}, [signal]}
  end
end
```

Every accessor today's macro emits keeps the same shape.

## Files to modify

### `lib/jido/action.ex`

1. Delete `defmacro __using__/1` (lines 145–~340).
2. Delete `@action_config_schema` (lines 84–~140).
3. Keep the runtime helpers (`Jido.Action.Schema.validate_*`).
4. Replace the macro body with:

   ```elixir
   defmacro __using__(_opts) do
     quote do
       use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Action]]

       @behaviour Jido.Action

       def __action__, do: true
     end
   end
   ```

### `lib/jido/dsl/action.ex`

```elixir
defmodule Jido.Dsl.Action do
  @action_section %Spark.Dsl.Section{
    name: :action,
    schema: [
      name: [type: {:custom, Jido.Util, :validate_name, []}, required: true],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string],
      path: [type: :atom,
             doc: "Atom slice key this action operates on. " <>
                  "Defaults to the agent's `path:` at routing time."],
      compensation: [type: :any,
                     doc: "Compensation declaration; see Jido.Action.Schema."],
      schema: [type: :any,
               doc: "Zoi or NimbleOptions schema validating this action's input."],
      output_schema: [type: :any,
                      doc: "Zoi schema validating this action's output."]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@action_section],
    transformers: [Jido.Dsl.Action.Transformers.GenerateAccessors]
end
```

### `lib/jido/sensor.ex`

Same treatment:

```elixir
defmacro __using__(_opts) do
  quote do
    use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Sensor]]

    @behaviour Jido.Sensor
  end
end
```

### `lib/jido/dsl/sensor.ex`

```elixir
defmodule Jido.Dsl.Sensor do
  @sensor_section %Spark.Dsl.Section{
    name: :sensor,
    schema: [
      name: [type: {:custom, Jido.Util, :validate_name, []}, required: true],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string],
      schema: [type: :any,
               doc: "Zoi schema validating sensor config."]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@sensor_section],
    transformers: [Jido.Dsl.Sensor.Transformers.GenerateAccessors]
end
```

### Every in-tree action / sensor module

- Every `use Jido.Action, …` in `lib/`, `test/`, and the framework's
  in-tree action modules:
  - `lib/jido/pod/actions/mutate.ex`
  - `lib/jido/pod/actions/mutate_progress.ex`
  - `lib/jido/pod/actions/query_topology.ex`
  - `lib/jido/pod/actions/query_nodes.ex`
  - `lib/jido/pod/bus_plugin/auto_unsubscribe_child.ex`
  - `lib/jido/ai/react/action/*.ex` (all the ReAct-step actions)
  - `test/jido/**/*.exs` test action modules
- Every `use Jido.Sensor, …` in `lib/jido/sensors/` and tests.

A representative migration:

```elixir
# before
defmodule MyApp.Increment do
  use Jido.Action,
    name: "increment",
    description: "Increment the counter slice",
    path: :counter,
    schema: [by: [type: :integer, default: 1]]

  def run(signal, slice, _opts, _ctx) do
    {:ok, %{slice | count: (slice[:count] || 0) + signal.data.by}, []}
  end
end

# after
defmodule MyApp.Increment do
  use Jido.Action

  action do
    name "increment"
    description "Increment the counter slice"
    path :counter
    schema [by: [type: :integer, default: 1]]
  end

  def run(signal, slice, _opts, _ctx) do
    {:ok, %{slice | count: (slice[:count] || 0) + signal.data.by}, []}
  end
end
```

## Files to create

- `lib/jido/dsl/action/transformers/generate_accessors.ex`
- `lib/jido/dsl/sensor/transformers/generate_accessors.ex`
- `test/jido/dsl/action_test.exs`
- `test/jido/dsl/sensor_test.exs`

## Files to delete

None. Each `__using__/1` is replaced in place.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean.
- New `test/jido/dsl/action_test.exs` and `sensor_test.exs` cover:
  1. `use Jido.Action` with sectioned DSL produces the same accessors
     as the legacy keyword form.
  2. `path:` defaulting still works (an action with no `path:` falls
     back to the agent's path at routing time).
  3. `schema:` and `output_schema:` are exposed as Zoi schemas.
  4. Sensor accessors round-trip.

## Out of scope

- The extension contribution story for slices / plugins. Task 0037.
- Generated cheat sheets / migration guide. Task 0038.
- Igniter recipes (`mix jido.gen.action` etc.). Out of scope for this
  ADR.

## Risks

- **`compensation:` shape.** `Jido.Action.Schema.validate_config_schema/2`
  is a Zoi refinement today; `:any` plus a `:custom` validator that
  delegates to the same function preserves behavior. Verify with a
  test that pulls the existing compensation cases.
- **`schema:` accepting both Zoi and NimbleOptions shapes.**
  `lib/jido/action.ex` accepts either form today (the comment in
  `lib/jido/agent.ex` calls this out). The DSL stores the value
  verbatim and the runtime branches at validation time, exactly as
  today.
- **Path defaulting.** `Jido.Agent.cmd/2` resolves `action.path()`
  and falls back to the agent's path. The transformer must emit a
  `path/0` that returns the configured atom or `nil`; the existing
  fallback in `cmd/2` does the rest.
- **Test action module count.** Many tests define small inline
  actions. The migration is mechanical; do it in passes to keep
  diff review tractable.
