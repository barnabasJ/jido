---
name: Task 0035 — Port `use Jido.Slice`, `use Jido.Plugin`, `use Jido.Middleware` to Spark DSL
description: Replace the `Jido.Slice`, `Jido.Plugin`, and `Jido.Middleware` `__using__` macros with Spark DSL definitions in `Jido.Dsl.Slice`, `Jido.Dsl.Plugin`, `Jido.Dsl.Middleware`. Slice gets a sectioned DSL covering its current Zoi `@slice_config_schema` (`name`, `path`, `actions`, `schema`, `config_schema`, `signal_routes`, `subscriptions`, `schedules`, `capabilities`, `requires`, `singleton`, `description`, `category`, `vsn`, `otp_app`, `tags`). Plugin's DSL composes the slice DSL plus the `@behaviour Jido.Middleware` declaration. Middleware's DSL is minimal (essentially `@behaviour`); a section is added if/when middleware needs configurable options. Every in-tree slice / plugin / middleware module rewrites; framework-default slices, `lib/jido/middleware/persister.ex`, `Jido.AI.ReAct`, etc. all migrate in this commit.
---

# Task 0035 — Port slice / plugin / middleware to Spark DSL

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1, §4 mechanics (the *typed-section contribution* half lands in [task 0037](0037-extensions-contribute-dsl-sections.md)).
- Depends on: [task 0034](0034-port-jido-agent-to-spark.md). The agent's `slices` / `plugins` / `middleware` sections must be in place so a slice / plugin / middleware module can register through them.
- Blocks: [task 0036](0036-port-action-and-sensor-to-spark.md), [task 0037](0037-extensions-contribute-dsl-sections.md).
- Leaves tree: **red** — actions and sensors still use the legacy macros, so any test composing all four surfaces fails. Slice / plugin / middleware *unit* tests pass.

## Context

`lib/jido/slice.ex` carries a Zoi `@slice_config_schema` and an
`__using__` macro that emits one accessor per option (`name/0`,
`path/0`, `actions/0`, `schema/0`, `signal_routes/0`, `subscriptions/0`,
…) plus a `manifest/0` and `plugin_spec/1`. `lib/jido/plugin.ex` is a
4-line shim that delegates to `Jido.Slice` and adds a
`@behaviour Jido.Middleware`. `lib/jido/middleware.ex` is a single-tier
behaviour with no configuration shape.

ADR 0023 §1 calls for replacing all three with Spark DSLs. The slice
surface benefits the most — the option list is the largest and the
hand-rolled validators (`validate_slice_name/2`,
`validate_slice_actions/2`) and `defoverridable` block are the
exact thing Spark replaces.

## Goal

After this commit:

```elixir
defmodule MyApp.ChatSlice do
  use Jido.Slice

  slice do
    name "chat"
    path :chat
    description "Chat history slice"
    schema Zoi.object(%{
      messages: Zoi.list(Zoi.any()) |> Zoi.default([]),
      model: Zoi.string() |> Zoi.default("gpt-4")
    })
  end

  actions do
    action MyApp.Actions.SendMessage
    action MyApp.Actions.ListHistory
  end

  signal_routes do
    route "chat.send", MyApp.Actions.SendMessage
    route "chat.history", MyApp.Actions.ListHistory
  end

  capabilities do
    capability :messaging
    capability :chat
  end
end
```

```elixir
defmodule MyApp.ChatPlugin do
  use Jido.Plugin

  slice do
    name "chat_plugin"
    path :chat_plugin
    schema Zoi.object(%{messages: Zoi.list(Zoi.any()) |> Zoi.default([])})
  end

  actions do
    action MyApp.Actions.PluginAction
  end

  signal_routes do
    route "chat.intercepted", MyApp.Actions.PluginAction
  end

  @impl Jido.Middleware
  def on_signal(signal, ctx, _opts, next) do
    next.(signal, ctx)
  end
end
```

```elixir
defmodule MyApp.RetryMiddleware do
  use Jido.Middleware

  middleware do
    description "Retries on transient failures."
    schema [
      max_retries: [type: :pos_integer, default: 3],
      backoff_ms: [type: :pos_integer, default: 100]
    ]
  end

  @impl Jido.Middleware
  def on_signal(signal, ctx, opts, next) do
    # ... use opts.max_retries / opts.backoff_ms ...
    next.(signal, ctx)
  end
end
```

`MyApp.ChatSlice.name/0`, `.path/0`, `.actions/0`, `.schema/0`,
`.config_schema/0`, `.signal_routes/0`, `.subscriptions/0`,
`.schedules/0`, `.capabilities/0`, `.singleton?/0`, `.requires/0`,
`.manifest/0`, `.plugin_spec/1` — every accessor today's macro emits
keeps the same shape. The `__jido_slice__/0` and `__jido_plugin__/0`
markers are emitted unchanged.

## Files to modify

### `lib/jido/slice.ex`

1. Delete `defmacro __using__/1` (lines 159–320).
2. Delete `@slice_config_schema` (lines 56–129).
3. Keep `validate_slice_name/2` and `validate_slice_actions/2` —
   they're called by Spark's `:custom` validator type from the new
   DSL schema.
4. Replace the macro body with:

   ```elixir
   defmacro __using__(_opts) do
     quote do
       use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Slice]]

       @doc false
       @spec __jido_slice__() :: true
       def __jido_slice__, do: true
     end
   end
   ```

### `lib/jido/dsl/slice.ex`

Replace placeholder with:

```elixir
defmodule Jido.Dsl.Slice do
  @slice_section %Spark.Dsl.Section{
    name: :slice,
    schema: [
      name: [type: {:custom, Jido.Slice, :validate_slice_name, []}, required: true],
      path: [type: :atom, required: true],
      description: [type: :string],
      category: [type: :string],
      vsn: [type: :string],
      otp_app: [type: :atom],
      schema: [type: :any],
      config_schema: [type: :any],
      tags: [type: {:list, :string}, default: []],
      singleton: [type: :boolean, default: false]
    ]
  }

  @action_entity %Spark.Dsl.Entity{
    name: :action,
    target: Jido.Slice.ActionEntry,
    args: [:module],
    no_depend_modules: [:module],
    schema: [module: [type: :atom, required: true]]
  }

  @actions_section %Spark.Dsl.Section{
    name: :actions,
    entities: [@action_entity]
  }

  @route %Spark.Dsl.Entity{
    name: :route,
    target: Jido.Slice.RouteEntry,
    args: [:type, :action],
    schema: [
      type: [type: :string, required: true],
      action: [type: {:or, [:atom, :mfa]}, required: true],
      priority: [type: :integer, default: 0],
      match: [type: {:fun, 1}],
      static: [type: :map]
    ]
  }

  @signal_routes_section %Spark.Dsl.Section{
    name: :signal_routes,
    entities: [@route]
  }

  @subscription %Spark.Dsl.Entity{
    name: :subscription,
    target: Jido.Slice.SubscriptionEntry,
    args: [:sensor, :config],
    schema: [
      sensor: [type: :atom, required: true],
      config: [type: :map, default: %{}]
    ]
  }

  @subscriptions_section %Spark.Dsl.Section{
    name: :subscriptions,
    entities: [@subscription]
  }

  @schedule %Spark.Dsl.Entity{
    name: :schedule,
    target: Jido.Slice.ScheduleEntry,
    args: [:cron, :action],
    schema: [
      cron: [type: :string, required: true],
      action: [type: :atom, required: true],
      data: [type: :map, default: %{}]
    ]
  }

  @schedules_section %Spark.Dsl.Section{
    name: :schedules,
    entities: [@schedule]
  }

  @capability %Spark.Dsl.Entity{
    name: :capability,
    target: Jido.Slice.CapabilityEntry,
    args: [:name],
    schema: [name: [type: :atom, required: true]]
  }

  @capabilities_section %Spark.Dsl.Section{
    name: :capabilities,
    entities: [@capability]
  }

  @requires_entity %Spark.Dsl.Entity{
    name: :requires,
    target: Jido.Slice.RequiresEntry,
    args: [:kind, :name],
    schema: [
      kind: [type: {:in, [:config, :app, :plugin, :slice]}, required: true],
      name: [type: :atom, required: true]
    ]
  }

  @requires_section %Spark.Dsl.Section{
    name: :requires,
    entities: [@requires_entity]
  }

  use Spark.Dsl.Extension,
    sections: [
      @slice_section,
      @actions_section,
      @signal_routes_section,
      @subscriptions_section,
      @schedules_section,
      @capabilities_section,
      @requires_section
    ],
    transformers: [Jido.Dsl.Slice.Transformers.GenerateAccessors]
end
```

The `GenerateAccessors` transformer emits the same set of public
functions the old `__using__/1` emitted: `name/0`, `path/0`,
`actions/0`, `description/0`, `category/0`, `vsn/0`, `otp_app/0`,
`schema/0`, `config_schema/0`, `tags/0`, `capabilities/0`,
`singleton?/0`, `requires/0`, `signal_routes/0`, `subscriptions/0`,
`schedules/0`, `manifest/0`, `plugin_spec/1`,
`__plugin_metadata__/0`, plus the `defoverridable` declarations.

### `lib/jido/plugin.ex`

```elixir
defmodule Jido.Plugin do
  @moduledoc """
  A Plugin is a Slice + Middleware in one module. `use Jido.Plugin`
  is equivalent to `use Jido.Slice` plus `@behaviour Jido.Middleware`,
  with an additional `__jido_plugin__/0` marker.
  """

  defmacro __using__(_opts) do
    quote do
      use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Plugin]]

      @doc false
      @spec __jido_slice__() :: true
      def __jido_slice__, do: true

      @doc false
      @spec __jido_plugin__() :: true
      def __jido_plugin__, do: true

      @behaviour Jido.Middleware
    end
  end
end
```

### `lib/jido/dsl/plugin.ex`

Plugins compose the slice extension plus a placeholder for any
plugin-specific middleware-side options:

```elixir
defmodule Jido.Dsl.Plugin do
  use Spark.Dsl.Extension,
    sections: Jido.Dsl.Slice.sections(),
    transformers: [Jido.Dsl.Slice.Transformers.GenerateAccessors]
end
```

(For v1 we deliberately re-export the slice sections rather than
defining a separate plugin DSL; if a future plugin needs
middleware-specific config options, we add a `middleware do … end`
section to `Jido.Dsl.Plugin`. Out of scope here; documented in the
ADR's Follow-ups.)

### `lib/jido/middleware.ex`

```elixir
defmodule Jido.Middleware do
  @callback on_signal(...) :: ...

  defmacro __using__(_opts) do
    quote do
      use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Middleware]]

      @behaviour Jido.Middleware
    end
  end
end
```

### `lib/jido/dsl/middleware.ex`

```elixir
defmodule Jido.Dsl.Middleware do
  @middleware_section %Spark.Dsl.Section{
    name: :middleware,
    schema: [
      description: [type: :string],
      schema: [type: :keyword_list, default: [],
               doc: "NimbleOptions schema validating the per-registration opts arg."]
    ]
  }

  use Spark.Dsl.Extension, sections: [@middleware_section]
end
```

The middleware section is intentionally minimal: most middleware
modules don't have shape beyond their behaviour callback. The
`schema:` option is for middleware authors who want to declare what
their `opts` arg shape looks like; `Jido.AgentServer.compose_chain/1`
can then validate `{Mod, opts}` registrations against this schema at
chain-build time, rather than letting bad opts crash mid-signal.

### `lib/jido/slice/instance.ex`

Created in [task 0032](0032-framework-slices-attachment-option.md);
this task does not change its shape, but it does extend
`Jido.Slice.Instance.new/1` to accept the entries the `Jido.Dsl.Agent`
slices section produces (`%Jido.Slice.Instance{module: …, config: …}`
already-constructed structs vs. `Module` / `{Module, config}` legacy
shapes). The agent transformer in task 0034 produces the struct
form directly; the legacy shapes remain accepted for
backwards-compat with task 0032's tests.

### Every in-tree slice / plugin / middleware module

Migrate to the sectioned DSL:

- `lib/jido/identity/slice.ex` (renamed from `plugin.ex` per task 0032)
- `lib/jido/memory/slice.ex` (renamed from `plugin.ex` per task 0032)
- `lib/jido/thread/slice.ex` (renamed from `plugin.ex` per task 0032)
- `lib/jido/pod/plugin.ex`
- `lib/jido/pod/bus_plugin.ex`
- `lib/jido/middleware/persister.ex`
- `lib/jido/middleware/retry.ex` (if it exists; per ADR 0014 follow-ups)
- `lib/jido/ai/react.ex` (the `Jido.AI.ReAct` slice)
- Every `use Jido.Slice` / `use Jido.Plugin` / `use Jido.Middleware`
  in `test/`

A representative slice migration:

```elixir
# before
defmodule MyApp.ChatSlice do
  use Jido.Slice,
    name: "chat",
    path: :chat,
    actions: [SendMessage, ListHistory],
    schema: Zoi.object(%{messages: Zoi.list(Zoi.any()) |> Zoi.default([])}),
    signal_routes: [
      {"chat.send", SendMessage},
      {"chat.history", ListHistory}
    ]
end

# after
defmodule MyApp.ChatSlice do
  use Jido.Slice

  slice do
    name "chat"
    path :chat
    schema Zoi.object(%{messages: Zoi.list(Zoi.any()) |> Zoi.default([])})
  end

  actions do
    action SendMessage
    action ListHistory
  end

  signal_routes do
    route "chat.send", SendMessage
    route "chat.history", ListHistory
  end
end
```

## Files to create

- `lib/jido/dsl/slice/transformers/generate_accessors.ex`
- `lib/jido/slice/action_entry.ex` (entity target struct)
- `lib/jido/slice/route_entry.ex`
- `lib/jido/slice/subscription_entry.ex`
- `lib/jido/slice/schedule_entry.ex`
- `lib/jido/slice/capability_entry.ex`
- `lib/jido/slice/requires_entry.ex`
- `test/jido/dsl/slice_test.exs`
- `test/jido/dsl/plugin_test.exs`
- `test/jido/dsl/middleware_test.exs`

## Files to delete

None. The old `__using__/1` body in each of `slice.ex`, `plugin.ex`,
`middleware.ex` is *replaced* in place.

## Acceptance

- `mix compile --warnings-as-errors` clean for `lib/`. Tests for
  agent + slice + plugin + middleware integration pass; tests for
  action / sensor surfaces still red until task 0036.
- A representative test (`test/jido/dsl/slice_test.exs`) covers:
  1. `use Jido.Slice` with sectioned DSL produces the same
     `name/0` / `path/0` / `actions/0` / `schema/0` / `signal_routes/0`
     / `manifest/0` / `plugin_spec/1` outputs as the legacy keyword form.
  2. The `__jido_slice__/0` marker is emitted.
  3. A `use Jido.Plugin` module also has `__jido_plugin__/0`.
  4. A `use Jido.Plugin` module placed in `slices: [...]` still raises
     the task 0032 error message.
  5. A bare slice placed in `plugins: [...]` still raises (task 0029
     enforcement, unchanged).
- All in-tree slices / plugins / middleware compile and behave the
  same against `mix test test/jido/agent/`.

## Out of scope

- Letting a slice / plugin **contribute** a section to a host agent's
  DSL — the Ash-style "`use Jido.Agent, extensions: [Jido.AI.ReAct]`
  unlocks `react do … end`" story. That's task 0037.
- Action / sensor migration. Task 0036.
- Documentation / cheat sheets. Task 0038.

## Risks

- **Schema-merge accuracy.** `Jido.Agent.Schema.merge_with_plugins/2`
  reads each slice's `schema/0` to merge into the agent's combined
  schema. The DSL must produce a `schema/0` that returns exactly the
  same Zoi struct (or `nil` when unset) the legacy macro produced.
  Pin with a property test.
- **`defoverridable` set.** The current macro lists 17 functions in
  `defoverridable`. The transformer must list the same 17.
- **`Jido.Plugin`'s composition.** `use Jido.Plugin` previously
  expanded to `use Jido.Slice, opts; use Jido.Middleware`. Under the
  new design it expands to a single Spark DSL extension that
  registers both halves. Confirm with a test that
  `Jido.AI.ReAct.__jido_slice__/0`, `__jido_plugin__/0`, and
  `function_exported?(Jido.AI.ReAct, :on_signal, 4)` (when the user
  defines it) all hold simultaneously.
- **Test agent module renames.** Many tests define small inline
  agent / slice modules. Each rewrites to the sectioned DSL. The
  diff is large but each rewrite is mechanical; assign one folder
  per pass to keep PR review manageable.
- **`use Jido.Slice` in `lib/jido/middleware/`.** The `Persister`
  middleware is `use Jido.Middleware` only; it has no Slice half.
  Keep that exactly so — don't accidentally migrate it to a Plugin
  shape.
