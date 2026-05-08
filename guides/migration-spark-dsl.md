# Migrating to the Spark DSL

This guide walks through migrating an out-of-tree Jido codebase to the sectioned
**Spark DSL** surface that Jido ships today.

> ## Update — ADR 0028: `Jido.Plugin` retired
>
> The Plugin tier (Slice + Middleware combo in one module) was removed in v3.
> References below to `use Jido.Plugin` are historical — for any module that
> needs both a Slice and a Middleware half, declare `use Jido.Slice` and
> `@behaviour Jido.Middleware` on the same module and register it in both the
> agent's `slices do … end` block AND its `middleware: […]` keyword. See the
> [Migrating from `Jido.Plugin`](migration.md#migrating-from-jidoplugin-adr-0028)
> section in the v1 → v2 migration guide for the full recipe.

> ## Update — task 0053: `slices do … end` block
>
> Slice/plugin enumeration moved out of the `extensions: […]` flat list and into
> a typed `slices do slice :path, Module end` block on the agent. Middleware
> moved to a top-level `middleware: […]` opt on `use Jido.Agent` (ordering
> matters and a flat ordered list is the right shape). The `extensions: […]`
> keyword stays available for modules that contribute a typed DSL section to the
> host (e.g. `Jido.Slices.AiReact` to unlock `react do … end`) — it is no longer
> the channel for slice/plugin enumeration.
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
> Action modules no longer carry a `path :foo` field. The slice path for an
> action's return value is now resolved through a compile-time lookup table
> built from each slice's `signal_routes` — i.e. "the slice whose route points
> at this action owns its return value." Slices and plugins still declare an
> optional `path :foo` field on their own DSL, but the agent's `slices do …`
> mount path always wins. Most slices should omit the field entirely.
>
> The rest of this guide describes the original keyword-list → Spark migration;
> pair it with the `slices do …` shape above.

## Why we're migrating

The agent / slice / plugin / middleware / action / sensor / pod surfaces used to
be defined by a hand-rolled `__using__` macro that took a long keyword list:

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
`Spark.Dsl.Extension` module under `Jido.Dsl.<Kind>`, exposing one or more typed
sections (`agent do … end`, `signal_routes do … end`, `pod do topology … end`,
…). Introspection lives in per-DSL Info modules (`Jido.Dsl.<Kind>.Info`),
generated from the same section definitions. The single ordered
`extensions: [...]` keyword on `use Jido.Agent` replaces the old `slices:` /
`plugins:` / `middleware:` triple.

ADR 0023 (`guides/adr/0023-spark-dsl-and-registerable-extensions.md`) captures
the rationale: a typed compile-time surface with built-in cheat sheets,
formatter integration, IDE autocompletion, and a single ordered list with a
deterministic walker that classifies entries by their DSL.

The conversion is **mechanical**. There's no semantic change — `cmd/2`, `set/2`,
`validate/2`, `signal_routes/0`, `actions/0`, etc. all return the same shapes
they did before. The migration is just shape: keyword list → sectioned DSL.

## ADR 0025 directory layout — rename map

Independently of the Spark migration above,
[ADR 0025](adr/0025-extension-directory-layout.md) reorganized the four
extension surfaces (`slices/`, `plugins/`, `middlewares/`, `directives/`) into
top-level plural-namespaced directories with one module per file. Tasks
0044–0050 moved the built-in slices, middlewares, and the framework-directive
umbrella into the new shape; commit `b5a1c49` and tasks 0064–0065 then
reclassified the three non-pure cases (FSM, BusPlugin, Pod itself); task 0068
retired `Jido.Plugin` entirely. The table below is the consolidated before/after
— every public module-name change a v2-era external project sees on upgrade.

| Before                                         | After                                               | Task                                                            | Notes                                                                                                                                         |
| ---------------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `Jido.Memory.Slice`                            | `Jido.Slices.Memory`                                | [task 0044](tasks/0044-move-rename-memory-slice.md)             | namespace only                                                                                                                                |
| `Jido.Memory.Space`                            | `Jido.Slices.Memory.Space`                          | [task 0044](tasks/0044-move-rename-memory-slice.md)             | follows parent rename                                                                                                                         |
| `Jido.Memory.Actions.*`                        | `Jido.Slices.Memory.Actions.*`                      | [task 0044](tasks/0044-move-rename-memory-slice.md)             | follows parent rename                                                                                                                         |
| `Jido.Memory` (data type)                      | `Jido.Slices.Memory.State`                          | [task 0044](tasks/0044-move-rename-memory-slice.md)             | bare alias renamed to `.State` so it stops shadowing the slice DSL                                                                            |
| `Jido.Identity.Slice`                          | `Jido.Slices.Identity`                              | [task 0045](tasks/0045-move-rename-identity-slice.md)           | namespace only                                                                                                                                |
| `Jido.Identity.Actions.*`                      | `Jido.Slices.Identity.Actions.*`                    | [task 0045](tasks/0045-move-rename-identity-slice.md)           | follows parent rename                                                                                                                         |
| `Jido.Identity` (data type)                    | `Jido.Slices.Identity.State`                        | [task 0045](tasks/0045-move-rename-identity-slice.md)           | bare alias renamed to `.State`                                                                                                                |
| `Jido.Thread.Slice`                            | `Jido.Slices.Thread`                                | [task 0046](tasks/0046-move-rename-thread-slice.md)             | namespace only                                                                                                                                |
| `Jido.Thread.{Entry,EntryNormalizer,Store}`    | `Jido.Slices.Thread.{Entry,EntryNormalizer,Store}`  | [task 0046](tasks/0046-move-rename-thread-slice.md)             | follows parent rename                                                                                                                         |
| `Jido.Thread.Store.Adapters.*`                 | `Jido.Slices.Thread.Store.Adapters.*`               | [task 0046](tasks/0046-move-rename-thread-slice.md)             | follows parent rename                                                                                                                         |
| `Jido.Thread.Actions.*`                        | `Jido.Slices.Thread.Actions.*`                      | [task 0046](tasks/0046-move-rename-thread-slice.md)             | follows parent rename                                                                                                                         |
| `Jido.Thread` (data type)                      | `Jido.Slices.Thread.State`                          | [task 0046](tasks/0046-move-rename-thread-slice.md)             | bare alias renamed to `.State`                                                                                                                |
| `Jido.AI.ReAct`                                | `Jido.Slices.AiReact`                               | [task 0047](tasks/0047-move-rename-ai-react-slice.md)           | slice DSL relocated; the `Jido.AI` facade itself stays put                                                                                    |
| `Jido.AI.Turn`                                 | `Jido.Slices.AiReact.Turn`                          | [task 0047](tasks/0047-move-rename-ai-react-slice.md)           | follows parent rename                                                                                                                         |
| `Jido.AI.ToolAdapter`                          | `Jido.Slices.AiReact.ToolAdapter`                   | [task 0047](tasks/0047-move-rename-ai-react-slice.md)           | follows parent rename                                                                                                                         |
| `Jido.AI.Actions.*`                            | `Jido.Slices.AiReact.Actions.*`                     | [task 0047](tasks/0047-move-rename-ai-react-slice.md)           | follows parent rename                                                                                                                         |
| `Jido.AI.Directive.{LLMCall,ToolExec}`         | `Jido.Slices.AiReact.Directives.{LLMCall,ToolExec}` | [task 0047](tasks/0047-move-rename-ai-react-slice.md)           | singular `Directive` → plural `Directives` to match the framework convention                                                                  |
| `Jido.Middleware.Retry`                        | `Jido.Middlewares.Retry`                            | [task 0048](tasks/0048-move-rename-middlewares.md)              | namespace only; the framework base `Jido.Middleware` is untouched                                                                             |
| `Jido.Middleware.Persister`                    | `Jido.Middlewares.Persister`                        | [task 0048](tasks/0048-move-rename-middlewares.md)              | namespace only                                                                                                                                |
| `Jido.Plugin.FSM`                              | `Jido.Plugins.FSM` _(interim)_                      | [task 0049](tasks/0049-move-rename-fsm-plugin.md)               | superseded by the reclass row below — skip straight to `Jido.Slices.FSM`                                                                      |
| `Jido.Plugins.FSM`                             | `Jido.Slices.FSM`                                   | commit `b5a1c49`                                                | reclassified Plugin → Slice; FSM exposes no `Jido.Middleware` callbacks, so the Plugin label was wrong                                        |
| `Jido.Plugins.FSM.Transition`                  | `Jido.Slices.FSM.Transition`                        | commit `b5a1c49`                                                | follows parent rename                                                                                                                         |
| `Jido.Agent.Directive` (umbrella)              | `Jido.Directives`                                   | [task 0050](tasks/0050-lift-framework-directives.md)            | umbrella slimmed to typespec + helpers; constructor API (`emit/2`, `spawn_agent/3`, …) unchanged                                              |
| `Jido.Agent.Directive.{Emit,Spawn,Schedule,…}` | `Jido.Directives.{Emit,Spawn,Schedule,…}`           | [task 0050](tasks/0050-lift-framework-directives.md)            | one struct per file under `lib/jido/directives/`; full set listed in [`directives.md`](directives.md)                                         |
| `Jido.Pod.BusPlugin`                           | `Jido.Slices.ChildBus`                              | [task 0064](tasks/0064-classify-and-relocate-pod-bus-plugin.md) | reclassified Plugin → Slice + renamed to drop the pod-specific framing (parallel to FSM — no middleware behaviour was used)                   |
| `Jido.Pod.BusPlugin.AutoSubscribeChild`        | `Jido.Slices.ChildBus.AutoSubscribeChild`           | [task 0064](tasks/0064-classify-and-relocate-pod-bus-plugin.md) | follows parent rename                                                                                                                         |
| `Jido.Pod.BusPlugin.AutoUnsubscribeChild`      | `Jido.Slices.ChildBus.AutoUnsubscribeChild`         | [task 0064](tasks/0064-classify-and-relocate-pod-bus-plugin.md) | follows parent rename                                                                                                                         |
| `Jido.Pod`                                     | `Jido.Slices.Pod`                                   | [task 0065](tasks/0065-move-pod-into-slices.md)                 | full subtree move; the slice atom `:pod` and the contributed `pod do … end` host section keep their names (both module-keyed)                 |
| `Jido.Pod.{Runtime,Topology,Info,Mutation,…}`  | `Jido.Slices.Pod.{Runtime,Topology,…}`              | [task 0065](tasks/0065-move-pod-into-slices.md)                 | follows parent rename                                                                                                                         |
| `Jido.Plugin` (the abstraction)                | **removed**                                         | [task 0068](tasks/0068-remove-jido-plugin.md)                   | port to `use Jido.Slice` + `@behaviour Jido.Middleware` — see [Migrating from `Jido.Plugin`](migration.md#migrating-from-jidoplugin-adr-0028) |

> **Plugin → Slice reclassifications.** Three ex-Plugin shapes ended up as plain
> Slices: `Jido.Plugins.FSM` (commit `b5a1c49`), `Jido.Pod.BusPlugin` (task
> 0064), and `Jido.Pod` itself (task 0065 finalized after task 0061's
> `use Jido.Plugin` → `use Jido.Slice` flip). All three implemented zero
> `Jido.Middleware` callbacks (`call/4`, `init/1`, `on_signal/4`); the Plugin
> label was carried by directory layout, not behaviour. Once they moved, the
> Plugin abstraction had no in-tree users and was removed in task 0068
> ([ADR 0028](adr/0028-deprecate-jido-plugin.md)). **If your own code does
> `use Jido.Plugin`:** grep your module for the three middleware callbacks. If
> none are implemented, port to `use Jido.Slice` alone. If any are, port to
> `use Jido.Slice` + `@behaviour Jido.Middleware` and mount the module in both
> `slices do … end` _and_ `middleware: […]` on the host agent — the recipe is in
> [Migrating from `Jido.Plugin`](migration.md#migrating-from-jidoplugin-adr-0028).

### Bulk-rewrite recipe

Run from the project root. The order matters — most-specific submodule prefixes
first, so the trailing bare-alias step at the bottom only catches the data-type
aliases nothing else has rewritten yet.

```sh
# 1. Slice DSL renames — fully-qualified prefixes that map 1:1.
sed -i 's|Jido\.Memory\.Slice|Jido.Slices.Memory|g'      $(rg -l 'Jido\.Memory\.Slice' --type elixir)
sed -i 's|Jido\.Identity\.Slice|Jido.Slices.Identity|g'  $(rg -l 'Jido\.Identity\.Slice' --type elixir)
sed -i 's|Jido\.Thread\.Slice|Jido.Slices.Thread|g'      $(rg -l 'Jido\.Thread\.Slice' --type elixir)
sed -i 's|Jido\.AI\.ReAct|Jido.Slices.AiReact|g'         $(rg -l 'Jido\.AI\.ReAct' --type elixir)
sed -i 's|Jido\.Plugin\.FSM|Jido.Slices.FSM|g'           $(rg -l 'Jido\.Plugin\.FSM' --type elixir)
sed -i 's|Jido\.Plugins\.FSM|Jido.Slices.FSM|g'          $(rg -l 'Jido\.Plugins\.FSM' --type elixir)
sed -i 's|Jido\.Pod\.BusPlugin|Jido.Slices.ChildBus|g'   $(rg -l 'Jido\.Pod\.BusPlugin' --type elixir)

# 2. Companion modules under each slice.
sed -i 's|Jido\.Memory\.Space|Jido.Slices.Memory.Space|g'             $(rg -l 'Jido\.Memory\.Space' --type elixir)
sed -i 's|Jido\.Memory\.Actions\.|Jido.Slices.Memory.Actions.|g'      $(rg -l 'Jido\.Memory\.Actions\.' --type elixir)
sed -i 's|Jido\.Identity\.Actions\.|Jido.Slices.Identity.Actions.|g'  $(rg -l 'Jido\.Identity\.Actions\.' --type elixir)
sed -i 's|Jido\.Thread\.Entry|Jido.Slices.Thread.Entry|g'             $(rg -l 'Jido\.Thread\.Entry' --type elixir)
sed -i 's|Jido\.Thread\.Store|Jido.Slices.Thread.Store|g'             $(rg -l 'Jido\.Thread\.Store' --type elixir)
sed -i 's|Jido\.Thread\.Actions\.|Jido.Slices.Thread.Actions.|g'      $(rg -l 'Jido\.Thread\.Actions\.' --type elixir)
sed -i 's|Jido\.AI\.Turn|Jido.Slices.AiReact.Turn|g'                  $(rg -l 'Jido\.AI\.Turn' --type elixir)
sed -i 's|Jido\.AI\.ToolAdapter|Jido.Slices.AiReact.ToolAdapter|g'    $(rg -l 'Jido\.AI\.ToolAdapter' --type elixir)
sed -i 's|Jido\.AI\.Actions\.|Jido.Slices.AiReact.Actions.|g'         $(rg -l 'Jido\.AI\.Actions\.' --type elixir)
sed -i 's|Jido\.AI\.Directive\.|Jido.Slices.AiReact.Directives.|g'    $(rg -l 'Jido\.AI\.Directive\.' --type elixir)

# 3. Built-in middlewares (framework base Jido.Middleware is untouched).
sed -i 's|Jido\.Middleware\.Retry|Jido.Middlewares.Retry|g'          $(rg -l 'Jido\.Middleware\.Retry' --type elixir)
sed -i 's|Jido\.Middleware\.Persister|Jido.Middlewares.Persister|g'  $(rg -l 'Jido\.Middleware\.Persister' --type elixir)

# 4. Framework directives umbrella + per-struct names.
sed -i 's|\bJido\.Agent\.Directive\b|Jido.Directives|g'  $(rg -l 'Jido\.Agent\.Directive' --type elixir)

# 5. Pod subtree (run after step 1 so Jido.Pod.BusPlugin is already gone).
sed -i 's|\bJido\.Pod\b|Jido.Slices.Pod|g'  $(rg -l '\bJido\.Pod\b' --type elixir)

# 6. Bare data-type aliases — last, with [^.] guard so dotted submodules
#    (already rewritten above) are skipped.
sed -i -E 's|(Jido\.Memory)([^A-Za-z0-9_.])|Jido.Slices.Memory.State\2|g'      $(rg -l '\bJido\.Memory\b' --type elixir)
sed -i -E 's|(Jido\.Memory)$|Jido.Slices.Memory.State|g'                       $(rg -l '\bJido\.Memory\b' --type elixir)
sed -i -E 's|(Jido\.Identity)([^A-Za-z0-9_.])|Jido.Slices.Identity.State\2|g'  $(rg -l '\bJido\.Identity\b' --type elixir)
sed -i -E 's|(Jido\.Identity)$|Jido.Slices.Identity.State|g'                   $(rg -l '\bJido\.Identity\b' --type elixir)
sed -i -E 's|(Jido\.Thread)([^A-Za-z0-9_.])|Jido.Slices.Thread.State\2|g'      $(rg -l '\bJido\.Thread\b' --type elixir)
sed -i -E 's|(Jido\.Thread)$|Jido.Slices.Thread.State|g'                       $(rg -l '\bJido\.Thread\b' --type elixir)

# Verify — should print nothing.
rg -nP '\b(Jido\.Memory(\.Slice|\.Space|\.Actions)?|Jido\.Identity(\.Slice|\.Actions)?|Jido\.Thread(\.Slice|\.Entry|\.Store|\.Actions)?|Jido\.AI\.(ReAct|Turn|ToolAdapter|Actions|Directive)|Jido\.Middleware\.(Retry|Persister)|Jido\.Plugin\.FSM|Jido\.Plugins\.FSM|Jido\.Agent\.Directive|Jido\.Pod\.BusPlugin|\bJido\.Pod\b)\b' .
```

The recipe leaves `use Jido.Plugin` sites untouched on purpose — those are not a
mechanical s/before/after/g (see the reclassification callout above).
Diff-review the rewrite before committing in case your own namespaces overlap a
`Jido.X` prefix.

## One agent module migration

Take a hypothetical agent that mounts the Memory slice and a few framework
defaults. We'll use `MyApp.SupportAgent` as the example.

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

| Old keyword                                  | New section/field                                                       |
| -------------------------------------------- | ----------------------------------------------------------------------- |
| `name:`                                      | `agent do name "…" end`                                                 |
| `description:`, `category:`, `tags:`, `vsn:` | `agent do … end` metadata fields                                        |
| `path:`                                      | `agent do path :foo end`                                                |
| `schema:`                                    | `agent do schema [...] end` (NimbleOptions) or `schema Zoi.object(...)` |
| `slices:`, `plugins:`, `middleware:`         | merged into `extensions: [...]` on `use Jido.Agent`                     |
| `signal_routes:`                             | `signal_routes do route "type", Action end`                             |
| `schedules:`                                 | `schedules do schedule "cron", "signal.type" end`                       |

The `extensions: […]` list is **single, ordered, classified by the walker**. The
compile-time `WalkExtensions` transformer inspects each entry —
`Spark.Dsl.is?(mod, Jido.Plugin)` for plugins, `Spark.Dsl.is?(mod, Jido.Slice)`
for slices, `Jido.Middleware` behaviour for middleware — and produces the same
internal `slices` / `plugins` / `middleware` lists today's runtime reads via
`Jido.Dsl.Agent.Info`.

### Reading the migrated agent

Anything that used to read `MyAgent.slices/0`, `MyAgent.plugins/0`,
`MyAgent.middleware/0`, `MyAgent.signal_routes/0`, etc. continues to work —
those public accessors still exist and read from the Spark DSL state. The
canonical introspection path for new code is `Jido.Dsl.Agent.Info` (or
`Jido.Dsl.Slice.Info` for slices, etc.):

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

`Jido.Slices.Memory` is a working in-tree slice — declares a name, path, schema,
routes, and capabilities.

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

- **`slice do … end`** is required — a slice without `name` and `path` fails
  Spark verification at compile time.
- **`signal_routes do … end`** is required for slices: per task 0039
  (`guides/tasks/0039-slices-must-declare-schema-and-routes.md`), every slice
  must declare at least one route, otherwise it's pure data with no way to
  participate in the signal pipeline.
- **`capabilities`, `requires`, `subscriptions`, `schedules`** are each their
  own optional section.
- **`config_schema` vs `schema`**: `schema` validates the slice's _runtime
  state_; `config_schema` validates the per-host configuration map (the second
  tuple element in `{Slice, %{...}}`).

## One plugin module migration

`Jido.Plugin` was retired in v3 ([ADR 0028](adr/0028-deprecate-jido-plugin.md))
— the table above lists it under the `Jido.Plugin (the abstraction) → removed`
row. The Slice + Middleware combo it represented now expresses as
`use Jido.Slice` + `@behaviour Jido.Middleware` on the same module, mounted
explicitly in both `slices do … end` _and_ `middleware: […]` on the host agent.
The full before/after recipe lives in
[Migrating from `Jido.Plugin`](migration.md#migrating-from-jidoplugin-adr-0028);
see also the [reclassification callout](#adr-0025-directory-layout--rename-map)
above for the audit checklist (do you actually implement any middleware
callback?). For the slice half on its own, the
[One slice module migration](#one-slice-module-migration) section above is the
recipe.

## The `extensions: [...]` opt-in

The agent's `extensions: […]` keyword is the single ordered registration list.
Each entry can be a **bare module**, a **`{module, config_map}` tuple**, or —
when the slice opts into the contribution mechanism — a bare module whose typed
configuration block lives directly on the host agent.

### Mode 1 — `extensions: [Mod]` (no per-host config needed)

```elixir
use Jido.Agent, extensions: [Jido.Slices.Identity]

agent do
  name "support_agent"
  path :state
  schema []
end
```

Identity slice has empty `config_schema/0`, so the bare module form suffices.
Schema defaults seed `agent.state[:identity]` at `Jido.Agent.new/1`.

### Mode 2 — `extensions: [{Mod, %{...}}]` (per-host config)

When a slice/plugin declares a `config_schema/0` that the host needs to
override:

```elixir
use Jido.Agent, extensions: [
  {Jido.Slices.Memory, %{kind: :persistent}}
]
```

The map is validated against the slice's `config_schema` and shallow-merged on
top of the slice's schema defaults at `new/1` time.

### Mode 3 — typed contribution block

When the slice opts in via `use Jido.Slice.Extension, host_section: :foo`, the
host gets a typed `foo do … end` block on the agent itself:

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

The contribution mechanism gets you compile-time validation of the config map
plus ExDoc-rendered docs for the contributed section under the agent's reference
page.

### When to use which

| Need                                                                            | Pattern                                        |
| ------------------------------------------------------------------------------- | ---------------------------------------------- |
| Slice has no per-host config (`config_schema: nil` or empty)                    | Mode 1 — bare module                           |
| Slice has `config_schema/0` and only one or two host overrides                  | Mode 2 — `{Mod, %{...}}` tuple                 |
| Slice has a richer config + you want compile-time validation + IDE autocomplete | Mode 3 — `host_section: :foo` + `foo do … end` |

The third mode is preferred for first-party extensions you ship as part of an
opinionated stack (`Jido.Slices.AiReact`, `Jido.Slices.Memory`,
`Jido.Slices.Identity`), since it produces the cleanest call sites.

### Renaming the mount path on a host

A contributed section gets a built-in `path:` field that lets the host rename
where the slice lives in `agent.state`:

```elixir
react do
  model "anthropic:claude-haiku-4-5-20251001"
  path :ai_state  # was :react by default
end
```

Now the slice's runtime data lives at `agent.state.ai_state` instead of
`agent.state.react`. Useful when you need two instances of the same slice
(different paths) on one agent.

## Common pitfalls

### Keyword `do:` blocks vs `do … end` blocks

Spark sections expect block form, not keyword form. Both compile, but the
keyword form is harder to read with multi-line content:

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

The formatter (with the `Spark.Formatter` plugin) auto-strips parentheses around
section / entity / option calls — so `name "x"` reads naturally without needing
`name("x")`.

### NimbleOptions-shaped section schemas vs Zoi-shaped runtime schemas

Each Spark `Section` has its own NimbleOptions schema validating the section
block at compile time. That's a different shape from the runtime schema you can
declare _inside_ the section.

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

Both schemas exist; they just validate at different layers. If you get a
`Spark.Options.ValidationError` at compile time, you're misnaming a section
field. If you get a Zoi or NimbleOptions error at runtime, your `state:` doesn't
match the runtime schema.

### Formatter quirks — `:locals_without_parens`

`mix spark.formatter --extensions Jido.Dsl.Agent,Jido.Dsl.Slice,…` regenerates
`.formatter.exs` with the right `:locals_without_parens` list. Run it after
introducing a new DSL section or entity, otherwise `mix format` will add
parentheses around your `name "x"` calls.

For a Jido project consuming the framework, this regeneration usually isn't
needed — the framework's exported `:locals_without_parens` flows in via
`import_deps: [:jido]` in your project's `.formatter.exs`. If you're authoring a
new extension, run `mix spark.formatter` against your own extension list.

### `extensions: […]` order matters

The walker classifies and registers entries left-to-right, so middleware order
on the chain follows declaration order. If `RetryMiddleware` should wrap
`PersisterMiddleware`, list `Retry` first.

### `path` must be unique across all extensions

Two slices that both declare `path :counter` raise at compile time:

```text
** (Spark.Error.DslError) Duplicate slice paths: [:counter]
```

Resolve with the contribution-mechanism `path:` override (Mode 3 above) or by
changing one of the slices.

### Slices must declare at least one route

Per task 0039 (`guides/tasks/0039-slices-must-declare-schema-and-routes.md`), a
slice without `signal_routes do route "…", Action end` fails Spark verification.
A "slice" with no routes is just data the agent could declare in its own schema
— there's no reason to put it in a separate module. If you're hitting this
verifier, either move the data into the agent's `agent do schema … end` or give
the slice a route.

### `Pod` agents — list `Jido.Slices.Pod` in `extensions:` and mount it

Pod is a regular slice + Spark extension. Listing it in `extensions:` opens the
contributed `pod do topology … end` block; mounting it under
`slices do slice :pod, Jido.Slices.Pod end` wires the pod slice into agent
state. To use a custom pod plugin, mount a different module at `:pod` and
configure it through `options:` on the slice mount.

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

A complete copy-pasteable example combining the migration steps. Drop this into
a fresh test file in your project; it should compile and demonstrate the
contribution mechanism end-to-end.

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

When converting an agent / slice / plugin / middleware module from the keyword
form, work top-to-bottom:

1. **Top of `defmodule`** — change `use Jido.X, name: "…", …` to a bare
   `use Jido.X` (or `use Jido.X, extensions: [...]` for agents that mount
   slices/plugins/middleware).
2. **Identity fields** — fold every `name:`, `description:`, `path:`, `schema:`,
   `config_schema:`, `category:`, `tags:`, `vsn:`, `otp_app:` into the
   **kind-named DSL section** (`agent do`, `slice do`, `action do`,
   `sensor do`).
3. **Routes** — move `signal_routes: [...]` into a
   `signal_routes do route "type", Action end` section.
4. **Schedules / subscriptions / capabilities / requires** — each gets its own
   section with `schedule "cron", "signal"` / `subscription Sensor, %{}` /
   `capability :name` / `requires :kind, :name` entries.
5. **Plugin / slice / middleware lists** — fold all three into a single ordered
   `extensions: [...]` list on `use Jido.Agent`.
6. **Contributed sections** — for agents that mount slices opting into the
   contribution mechanism, add the typed `<host_section> do … end` block on the
   agent.
7. **Run `mix compile --warnings-as-errors`** — Spark surfaces config errors at
   compile time. Errors should name the offending section / field clearly.
8. **Run `mix format`** — with the `Spark.Formatter` plugin (default for Jido
   projects via `import_deps: [:jido]`), section / entity calls lose their
   parentheses automatically.
9. **Update introspection callsites** — replace any `module.config_schema()`,
   `module.spec().config`, or `@xxx_config_schema` reads with the canonical
   `Jido.Dsl.<Kind>.Info.<accessor>(module)` path.

That's it. The runtime contract is unchanged; only the surface shape moves.

## Reference

- ADR 0023 — `guides/adr/0023-spark-dsl-and-registerable-extensions.md`
- [Jido.Agent DSL reference](../documentation/dsls/DSL-Jido.Dsl.Agent.md)
- [Jido.Slice DSL reference](../documentation/dsls/DSL-Jido.Dsl.Slice.md)
- [Jido.Plugin DSL reference](../documentation/dsls/DSL-Jido.Dsl.Plugin.md)
- [Jido.Middleware DSL reference](../documentation/dsls/DSL-Jido.Dsl.Middleware.md)
- [Jido.Action DSL reference](../documentation/dsls/DSL-Jido.Dsl.Action.md)
- [Jido.Sensor DSL reference](../documentation/dsls/DSL-Jido.Dsl.Sensor.md)
