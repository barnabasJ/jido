# Migrating to the Spark DSL

This guide walks through migrating an out-of-tree Jido codebase to the
sectioned **Spark DSL** surface that Jido ships today.

> ## Update — task 0053: `slices do … end` block
>
> Slice/plugin enumeration moved out of the `extensions: […]` flat list
> and into a typed `slices do slice :path, Module end` block on the
> agent. Middleware moved to a top-level `middleware: […]` opt on
> `use Jido.Agent` (ordering matters and a flat ordered list is the
> right shape). The `extensions: […]` keyword stays available for
> modules that contribute a typed DSL section to the host (e.g.
> `Jido.Slices.AiReact` to unlock `react do … end`) — it is no longer the
> channel for slice/plugin enumeration.
>
> ```elixir
> # Before:
> use Jido.Agent,
>   extensions: [Jido.Slices.Memory, Jido.Slices.FSM, Jido.Middlewares.Retry]
>
> # After:
> use Jido.Agent, middleware: [Jido.Slices.FSM, Jido.Middlewares.Retry]
>
> agent do
>   name "my_agent"
>   path :domain
> end
>
> slices do
>   slice :memory, Jido.Slices.Memory
>   slice :fsm, Jido.Slices.FSM
> end
> ```
>
> Action modules no longer carry a `path :foo` field. The slice path
> for an action's return value is now resolved through a compile-time
> lookup table built from each slice's `signal_routes` — i.e. "the
> slice whose route points at this action owns its return value."
> Slices and plugins still declare an optional `path :foo` field on
> their own DSL, but the agent's `slices do …` mount path always
> wins. Most slices should omit the field entirely.
>
> The rest of this guide describes the original keyword-list →
> Spark migration; pair it with the `slices do …` shape above.

## Why we're migrating

The agent / slice / plugin / middleware / action / sensor / pod surfaces
used to be defined by a hand-rolled `__using__` macro that took a long
keyword list:

```elixir
use Jido.Agent,
  name: "support_agent",
  path: :support,
  schema: [...],
  plugins: [Jido.Slices.Identity],
  slices: [{Jido.Slices.AiReact, ...}],
  middleware: [Jido.Middlewares.Persister],
  signal_routes: [{"counter.inc", IncAction}],
  schedules: [{"@daily", "report.run", job_id: :daily}]
```

Jido now defines those same surfaces with **Spark**. Each surface owns a
`Spark.Dsl.Extension` module under `Jido.Dsl.<Kind>`, exposing one or
more typed sections (`agent do … end`, `signal_routes do … end`,
`pod do topology … end`, …). Introspection lives in per-DSL Info
modules (`Jido.Dsl.<Kind>.Info`), generated from the same section
definitions. The single ordered `extensions: [...]` keyword on
`use Jido.Agent` replaces the old `slices:` / `plugins:` /
`middleware:` triple.

ADR 0023 (`guides/adr/0023-spark-dsl-and-registerable-extensions.md`)
captures the rationale: a typed compile-time surface with built-in cheat sheets,
formatter integration, IDE autocompletion, and a single ordered list
with a deterministic walker that classifies entries by their DSL.

The conversion is **mechanical**. There's no semantic change — `cmd/2`,
`set/2`, `validate/2`, `signal_routes/0`, `actions/0`, etc. all return
the same shapes they did before. The migration is just shape: keyword
list → sectioned DSL.

## One agent module migration

Take a hypothetical agent that mounts the Memory slice and a few
framework defaults. We'll use `MyApp.SupportAgent` as the example.

### Before (keyword form)

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent,
    name: "support_agent",
    description: "Agent backed by Jido.Slices.Memory",
    path: :state,
    schema: [
      messages: [type: {:list, :map}, default: []],
      memory_kind: [type: :atom, default: :ephemeral]
    ],
    slices: [Jido.Slices.Memory],
    signal_routes: [
      {"memory.store", Jido.Slices.Memory.Actions.Store},
      {"memory.recall", Jido.Slices.Memory.Actions.Recall}
    ]
end
```

### After (sectioned DSL)

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent, extensions: [Jido.Slices.Memory]

  agent do
    name "support_agent"
    description "Agent backed by Jido.Slices.Memory"
    path :state
    schema [
      messages: [type: {:list, :map}, default: []],
      memory_kind: [type: :atom, default: :ephemeral]
    ]
  end

  signal_routes do
    route "memory.store", Jido.Slices.Memory.Actions.Store
    route "memory.recall", Jido.Slices.Memory.Actions.Recall
  end
end
```

### What moved where

| Old keyword | New section/field |
|---|---|
| `name:` | `agent do name "…" end` |
| `description:`, `category:`, `tags:`, `vsn:` | `agent do … end` metadata fields |
| `path:` | `agent do path :foo end` |
| `schema:` | `agent do schema [...] end` (NimbleOptions) or `schema Zoi.object(...)` |
| `slices:`, `plugins:`, `middleware:` | merged into `extensions: [...]` on `use Jido.Agent` |
| `signal_routes:` | `signal_routes do route "type", Action end` |
| `schedules:` | `schedules do schedule "cron", "signal.type" end` |

The `extensions: […]` list is **single, ordered, classified by the
walker**. The compile-time `WalkExtensions` transformer inspects each
entry — `Spark.Dsl.is?(mod, Jido.Plugin)` for plugins,
`Spark.Dsl.is?(mod, Jido.Slice)` for slices,
`Jido.Middleware` behaviour for middleware — and produces the same
internal `slices` / `plugins` / `middleware` lists today's runtime
reads via `Jido.Dsl.Agent.Info`.

### Reading the migrated agent

Anything that used to read `MyAgent.slices/0`, `MyAgent.plugins/0`,
`MyAgent.middleware/0`, `MyAgent.signal_routes/0`, etc. continues to
work — those public accessors still exist and read from the Spark
DSL state. The canonical introspection path for new code is
`Jido.Dsl.Agent.Info` (or `Jido.Dsl.Slice.Info` for slices, etc.):

```elixir
alias Jido.Dsl.Agent.Info

Info.name(MyApp.SupportAgent)
# => "support_agent"

Info.path(MyApp.SupportAgent)
# => :support

Info.signal_routes(MyApp.SupportAgent)
# => [%Jido.Plugin.Routes.Spec{...}, ...]
```

## One slice module migration

`Jido.Slices.Memory` is a working in-tree slice — declares a name, path,
schema, routes, and capabilities.

### Before

```elixir
defmodule Jido.Slices.Memory do
  use Jido.Slice,
    name: "memory",
    path: :memory,
    description: "Working-memory slice",
    schema: Zoi.object(%{
      entries: Zoi.list(Zoi.any()) |> Zoi.default([]),
      kind: Zoi.atom() |> Zoi.default(:ephemeral)
    }),
    config_schema: Zoi.object(%{kind: Zoi.atom() |> Zoi.default(:ephemeral)}),
    capabilities: [:memory],
    signal_routes: [
      {"memory.store", Jido.Slices.Memory.Actions.Store},
      {"memory.recall", Jido.Slices.Memory.Actions.Recall}
    ]
end
```

### After

```elixir
defmodule Jido.Slices.Memory do
  use Jido.Slice

  slice do
    name "memory"
    path :memory
    description "Working-memory slice"
    schema Zoi.object(%{
      entries: Zoi.list(Zoi.any()) |> Zoi.default([]),
      kind: Zoi.atom() |> Zoi.default(:ephemeral)
    })
    config_schema Zoi.object(%{kind: Zoi.atom() |> Zoi.default(:ephemeral)})
  end

  signal_routes do
    route "memory.store", Jido.Slices.Memory.Actions.Store
    route "memory.recall", Jido.Slices.Memory.Actions.Recall
  end

  capabilities do
    capability :memory
  end
end
```

### Notes

- **`slice do … end`** is required — a slice without `name` and `path`
  fails Spark verification at compile time.
- **`signal_routes do … end`** is required for slices: per
  task 0039 (`guides/tasks/0039-slices-must-declare-schema-and-routes.md`), every
  slice must declare at least one route, otherwise it's pure data with no
  way to participate in the signal pipeline.
- **`capabilities`, `requires`, `subscriptions`, `schedules`** are each
  their own optional section.
- **`config_schema` vs `schema`**: `schema` validates the slice's *runtime
  state*; `config_schema` validates the per-host configuration map (the
  second tuple element in `{Slice, %{...}}`).

## One plugin module migration

`Jido.Slices.FSM` is the in-tree plugin example: a slice that exposes
state-machine transitions plus a small middleware half.

### Before

```elixir
defmodule Jido.Slices.FSM do
  use Jido.Plugin,
    name: "fsm",
    path: :fsm,
    description: "Finite-state machine plugin",
    schema: Zoi.object(%{
      state: Zoi.string() |> Zoi.optional(),
      initial_state: Zoi.string() |> Zoi.default("idle"),
      transitions: Zoi.map(Zoi.string(), Zoi.list(Zoi.string())) |> Zoi.default(%{})
    }),
    config_schema: Zoi.object(%{
      initial_state: Zoi.string() |> Zoi.default("idle"),
      transitions: Zoi.map(Zoi.string(), Zoi.list(Zoi.string())) |> Zoi.default(%{})
    }),
    signal_routes: [
      {"fsm.transition", Jido.Slices.FSM.Transition}
    ]

  @impl Jido.Middleware
  def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
end
```

### After

```elixir
defmodule Jido.Slices.FSM do
  use Jido.Plugin

  slice do
    name "fsm"
    path :fsm
    description "Finite-state machine plugin"
    schema Zoi.object(%{
      state: Zoi.string() |> Zoi.optional(),
      initial_state: Zoi.string() |> Zoi.default("idle"),
      transitions: Zoi.map(Zoi.string(), Zoi.list(Zoi.string())) |> Zoi.default(%{})
    })
    config_schema Zoi.object(%{
      initial_state: Zoi.string() |> Zoi.default("idle"),
      transitions: Zoi.map(Zoi.string(), Zoi.list(Zoi.string())) |> Zoi.default(%{})
    })
  end

  signal_routes do
    route "fsm.transition", Jido.Slices.FSM.Transition
  end

  @impl Jido.Middleware
  def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
end
```

`use Jido.Plugin` exposes the slice DSL's six sections (`slice`,
`signal_routes`, `subscriptions`, `schedules`, `capabilities`,
`requires`) plus the `Jido.Middleware` `@behaviour`. Implement
`on_signal/4` if the plugin actually wraps the pipeline; if it doesn't,
prefer `use Jido.Slice` instead.

## The `extensions: [...]` opt-in

The agent's `extensions: […]` keyword is the single ordered registration
list. Each entry can be a **bare module**, a **`{module, config_map}`
tuple**, or — when the slice opts into the contribution mechanism — a
bare module whose typed configuration block lives directly on the host
agent.

### Mode 1 — `extensions: [Mod]` (no per-host config needed)

```elixir
use Jido.Agent, extensions: [Jido.Slices.Identity]

agent do
  name "support_agent"
  path :state
  schema []
end
```

Identity slice has empty `config_schema/0`, so the bare module form
suffices. Schema defaults seed `agent.state[:identity]` at
`Jido.Agent.new/1`.

### Mode 2 — `extensions: [{Mod, %{...}}]` (per-host config)

When a slice/plugin declares a `config_schema/0` that the host needs to
override:

```elixir
use Jido.Agent, extensions: [
  {Jido.Slices.Memory, %{kind: :persistent}}
]
```

The map is validated against the slice's `config_schema` and
shallow-merged on top of the slice's schema defaults at `new/1` time.

### Mode 3 — typed contribution block

When the slice opts in via `use Jido.Slice.Extension, host_section: :foo`,
the host gets a typed `foo do … end` block on the agent itself:

```elixir
defmodule Jido.Slices.AiReact do
  use Jido.Plugin
  use Jido.Slice.Extension, host_section: :react

  slice do
    name "react"
    path :react
    config_schema Zoi.object(%{
      model: Zoi.any(),
      tools: Zoi.list(Zoi.any()) |> Zoi.default([]),
      max_iterations: Zoi.integer() |> Zoi.default(5)
    })
    schema Zoi.object(%{...})
  end

  signal_routes do
    route "react.start", Jido.Slices.AiReact.Actions.Start
  end
end

defmodule MyApp.LLMAgent do
  use Jido.Agent, extensions: [Jido.Slices.AiReact]

  agent do
    name "llm_agent"
    path :state
    schema []
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [MyApp.SearchTool, MyApp.SummarizeTool]
    max_iterations 7
  end
end
```

The contribution mechanism gets you compile-time validation of the
config map plus ExDoc-rendered docs for the contributed section under
the agent's reference page.

### When to use which

| Need | Pattern |
|---|---|
| Slice has no per-host config (`config_schema: nil` or empty) | Mode 1 — bare module |
| Slice has `config_schema/0` and only one or two host overrides | Mode 2 — `{Mod, %{...}}` tuple |
| Slice has a richer config + you want compile-time validation + IDE autocomplete | Mode 3 — `host_section: :foo` + `foo do … end` |

The third mode is preferred for first-party extensions you ship as part
of an opinionated stack (`Jido.Slices.AiReact`, `Jido.Slices.Memory`,
`Jido.Slices.Identity`), since it produces the cleanest call sites.

### Renaming the mount path on a host

A contributed section gets a built-in `path:` field that lets the host
rename where the slice lives in `agent.state`:

```elixir
react do
  model "anthropic:claude-haiku-4-5-20251001"
  path :ai_state  # was :react by default
end
```

Now the slice's runtime data lives at `agent.state.ai_state` instead of
`agent.state.react`. Useful when you need two instances of the same
slice (different paths) on one agent.

## Common pitfalls

### Keyword `do:` blocks vs `do … end` blocks

Spark sections expect block form, not keyword form. Both compile, but
the keyword form is harder to read with multi-line content:

```elixir
# Works but cramped:
agent do: (name "x"; path :y; schema [])

# Prefer:
agent do
  name "x"
  path :y
  schema []
end
```

The formatter (with the `Spark.Formatter` plugin) auto-strips parentheses
around section / entity / option calls — so `name "x"` reads naturally
without needing `name("x")`.

### NimbleOptions-shaped section schemas vs Zoi-shaped runtime schemas

Each Spark `Section` has its own NimbleOptions schema validating the
section block at compile time. That's a different shape from the
runtime schema you can declare *inside* the section.

```elixir
agent do
  # The `agent` section's NimbleOptions schema requires `name:` and accepts
  # `path: atom`, `schema: any`, etc. — that's compile-time validation of
  # the DSL itself.
  name "x"
  path :y
  schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
  # The `schema` *value* is a Zoi (or NimbleOptions) schema validating
  # `agent.state.y` at runtime.
end
```

Both schemas exist; they just validate at different layers. If you get
a `Spark.Options.ValidationError` at compile time, you're misnaming a
section field. If you get a Zoi or NimbleOptions error at runtime,
your `state:` doesn't match the runtime schema.

### Formatter quirks — `:locals_without_parens`

`mix spark.formatter --extensions Jido.Dsl.Agent,Jido.Dsl.Slice,…`
regenerates `.formatter.exs` with the right `:locals_without_parens`
list. Run it after introducing a new DSL section or entity, otherwise
`mix format` will add parentheses around your `name "x"` calls.

For a Jido project consuming the framework, this regeneration usually
isn't needed — the framework's exported `:locals_without_parens` flows
in via `import_deps: [:jido]` in your project's `.formatter.exs`. If
you're authoring a new extension, run `mix spark.formatter` against your
own extension list.

### `extensions: […]` order matters

The walker classifies and registers entries left-to-right, so middleware
order on the chain follows declaration order. If `RetryMiddleware`
should wrap `PersisterMiddleware`, list `Retry` first.

### `path` must be unique across all extensions

Two slices that both declare `path :counter` raise at compile time:

```text
** (Spark.Error.DslError) Duplicate slice paths: [:counter]
```

Resolve with the contribution-mechanism `path:` override (Mode 3 above)
or by changing one of the slices.

### Slices must declare at least one route

Per task 0039 (`guides/tasks/0039-slices-must-declare-schema-and-routes.md`), a
slice without `signal_routes do route "…", Action end` fails Spark
verification. A "slice" with no routes is just data the agent could
declare in its own schema — there's no reason to put it in a separate
module. If you're hitting this verifier, either move the data into the
agent's `agent do schema … end` or give the slice a route.

### `Pod` agents — list `Jido.Slices.Pod` in `extensions:` and mount it

Pod is a regular slice + Spark extension. Listing it in `extensions:`
opens the contributed `pod do topology … end` block; mounting it under
`slices do slice :pod, Jido.Slices.Pod end` wires the pod slice into agent
state. To use a custom pod plugin, mount a different module at `:pod`
and configure it through `options:` on the slice mount.

```elixir
defmodule MyApp.Workspace do
  use Jido.Agent, extensions: [Jido.Slices.Pod]

  agent do
    name "workspace"
  end

  slices do
    slice :pod, Jido.Slices.Pod
  end

  pod do
    topology %{
      coordinator: %{agent: MyApp.Coordinator, manager: :workers, activation: :eager},
      reviewer: %{agent: MyApp.Reviewer, manager: :workers, activation: :lazy}
    }
  end
end
```

## A clean walkthrough — `MyApp.SupportAgent`

A complete copy-pasteable example combining the migration steps. Drop
this into a fresh test file in your project; it should compile and
demonstrate the contribution mechanism end-to-end.

```elixir
# test/my_app/support_agent_smoke_test.exs
defmodule MyApp.Support.LookupAction do
  use Jido.Action

  action do
    name "lookup"
    path :support
    schema [query: [type: :string, required: true]]
  end

  @impl true
  def run(%Jido.Signal{data: %{query: q}}, slice, _opts, _ctx) do
    slice = slice || %{lookups: []}
    {:ok, Map.update(slice, :lookups, [q], &[q | &1]), []}
  end
end

defmodule MyApp.Support.NotesSlice do
  use Jido.Slice
  use Jido.Slice.Extension, host_section: :notes

  slice do
    name "support_notes"
    path :notes
    config_schema Zoi.object(%{
      retention_days: Zoi.integer() |> Zoi.default(30)
    })
    schema Zoi.object(%{
      entries: Zoi.list(Zoi.any()) |> Zoi.default([]),
      retention_days: Zoi.integer() |> Zoi.default(30)
    })
  end

  signal_routes do
    route "notes.append", MyApp.Support.LookupAction
  end
end

defmodule MyApp.SupportAgent do
  use Jido.Agent, extensions: [MyApp.Support.NotesSlice]

  agent do
    name "support_agent"
    description "Customer support agent"
    path :support
    schema [tickets: [type: {:list, :map}, default: []]]
  end

  signal_routes do
    route "support.lookup", MyApp.Support.LookupAction
  end

  notes do
    retention_days 60
  end
end

# Smoke checks
defmodule MyApp.SupportAgentSmokeTest do
  use ExUnit.Case

  test "agent metadata via Info" do
    assert Jido.Dsl.Agent.Info.name(MyApp.SupportAgent) == "support_agent"
    assert Jido.Dsl.Agent.Info.path(MyApp.SupportAgent) == :support
  end

  test "slice contributes a section schema" do
    agent = MyApp.SupportAgent.new()
    assert agent.state.notes.retention_days == 60
  end

  test "support.lookup route is wired" do
    agent = MyApp.SupportAgent.new()
    {:ok, agent2, _dirs} =
      MyApp.SupportAgent.cmd(agent, {MyApp.Support.LookupAction, %{query: "hi"}})

    assert agent2.state.support.lookups == ["hi"]
  end
end
```

## Conversion checklist

When converting an agent / slice / plugin / middleware module from the
keyword form, work top-to-bottom:

1. **Top of `defmodule`** — change `use Jido.X, name: "…", …` to a bare
   `use Jido.X` (or `use Jido.X, extensions: [...]` for agents that mount
   slices/plugins/middleware).
2. **Identity fields** — fold every `name:`, `description:`, `path:`,
   `schema:`, `config_schema:`, `category:`, `tags:`, `vsn:`, `otp_app:`
   into the **kind-named DSL section** (`agent do`, `slice do`,
   `action do`, `sensor do`).
3. **Routes** — move `signal_routes: [...]` into a
   `signal_routes do route "type", Action end` section.
4. **Schedules / subscriptions / capabilities / requires** — each gets
   its own section with `schedule "cron", "signal"` /
   `subscription Sensor, %{}` / `capability :name` /
   `requires :kind, :name` entries.
5. **Plugin / slice / middleware lists** — fold all three into a single
   ordered `extensions: [...]` list on `use Jido.Agent`.
6. **Contributed sections** — for agents that mount slices opting into
   the contribution mechanism, add the typed `<host_section> do … end`
   block on the agent.
7. **Run `mix compile --warnings-as-errors`** — Spark surfaces config
   errors at compile time. Errors should name the offending section /
   field clearly.
8. **Run `mix format`** — with the `Spark.Formatter` plugin (default
   for Jido projects via `import_deps: [:jido]`), section / entity calls
   lose their parentheses automatically.
9. **Update introspection callsites** — replace any `module.config_schema()`,
   `module.spec().config`, or `@xxx_config_schema` reads with the
   canonical `Jido.Dsl.<Kind>.Info.<accessor>(module)` path.

That's it. The runtime contract is unchanged; only the surface shape
moves.

## Reference

- ADR 0023 — `guides/adr/0023-spark-dsl-and-registerable-extensions.md`
- [Jido.Agent DSL reference](../documentation/dsls/DSL-Jido.Dsl.Agent.md)
- [Jido.Slice DSL reference](../documentation/dsls/DSL-Jido.Dsl.Slice.md)
- [Jido.Plugin DSL reference](../documentation/dsls/DSL-Jido.Dsl.Plugin.md)
- [Jido.Middleware DSL reference](../documentation/dsls/DSL-Jido.Dsl.Middleware.md)
- [Jido.Action DSL reference](../documentation/dsls/DSL-Jido.Dsl.Action.md)
- [Jido.Sensor DSL reference](../documentation/dsls/DSL-Jido.Dsl.Sensor.md)
