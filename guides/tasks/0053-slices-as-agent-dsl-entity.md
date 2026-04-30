---
name: Task 0053 — Lift slices into a first-class `slices do … end` agent DSL entity
description: Today every action under a slice redundantly declares `path :foo` even though its parent slice already declares the same path, because `__resolve_slice_path__` only consults `Jido.Dsl.Action.Info.path/1` (per-action) and falls back to the agent's own path — there is no slice→action inheritance. The fix is to make slices a proper DSL entity on the agent, owning the path-to-slice binding centrally. Replace the `extensions: […]` flat list (where slices/plugins/middleware are mixed and walked at compile time) with a `slices do slice :path, Module [do options [...] end] end` block on the agent. Slice modules stop declaring their own `path` — the agent does. Actions stop declaring `path :memory` / `path :thread` / etc. — the framework infers it from the slice that routes to them (or from the slice that owns the action's namespace). `middleware:` stays as a top-level `use Jido.Agent` option (ordering matters). Plugins register in both places: a `plugins do plugin :path, Module [do options [...] end] end` block for the same path-binding role slices have, and (when the user wants the plugin's DSL macros) on `use Jido.Agent, extensions: [...]`. The `{Module, opts}` tuple form for slice/plugin instantiation goes away — options live inline in the `do … end` block.
---

# Task 0053 — Lift slices into a first-class `slices do … end` agent DSL entity

- Depends on: [task 0043](0043-delete-misnamed-agent-helpers.md) (clears the misnamed helpers and rewrites their tests onto `cmd/2`, so the slice-binding refactor only has to update real action call sites).
- Blocks: arguably [task 0044](0044-move-rename-memory-slice.md) onwards — the slice rename tasks should land on top of this refactor so the new directory layout uses the new DSL idiomatically. (TBD; sequencing decision goes in the planning step.)
- Leaves tree: **green**.

## Problem

`Jido.Dsl.Agent.Transformers.GenerateAccessors.__resolve_slice_path__/1` is the function that decides "which slice does this action's return value go to?" — and it consults exactly two sources:

```elixir
defp __resolve_slice_path__(action) when is_atom(action) and not is_nil(action) do
  Code.ensure_loaded(action)

  case Jido.Dsl.Action.Info.path(action) do
    p when is_atom(p) and not is_nil(p) -> p
    _ -> Jido.Dsl.Agent.Info.path(__MODULE__)
  end
rescue
  UndefinedFunctionError -> Jido.Dsl.Agent.Info.path(__MODULE__)
end
```

(`lib/jido/dsl/agent/transformers/generate_accessors.ex:237-247`)

So:

1. The action's own `path :foo` declaration, if any.
2. The agent's own `path :bar` declaration, otherwise.

Slices are not consulted at all. A slice can declare `path :memory` (it does — see `lib/jido/memory/slice.ex:57`), but that path declaration only governs the slice's own state binding, not its actions' return routing. As a result every production action under `lib/jido/<slice>/actions/*.ex` redundantly redeclares `path :<slice>`:

```elixir
# lib/jido/memory/actions/ensure.ex
action do
  name "memory_ensure"
  path :memory      # ← duplicated; lib/jido/memory/slice.ex:57 already says this
  description "..."
  schema ...
end
```

Eight memory actions, three identity actions, three thread actions — eleven copies of the same path string. If a slice's path ever changes, eleven actions need to change with it. If a user writes a new action and forgets `path :memory`, the action silently writes to the agent's `:domain` slice instead of `:memory`, producing the kind of cross-slice corruption that surfaced when rewriting test fixtures in [task 0043](0043-delete-misnamed-agent-helpers.md).

Underneath this is a deeper structural problem: the agent currently has no first-class declaration of which slices it mounts. `use Jido.Agent, extensions: [Jido.Memory.Slice, Jido.SomePlugin, MyMiddleware]` is a flat list that `Jido.Dsl.Agent.Transformers.WalkExtensions` classifies at compile time by `Spark.Dsl.is?/2`. The agent's DSL does not say "this agent has slice X at path :foo with options Y" — the slice itself self-describes via its own DSL, and the agent silently inherits whatever path the slice says.

## Target shape

Make slices a proper DSL entity *on the agent*. **Plugins register the same way** — they are just slices that happen to come from a plugin module. Middleware stays at the top, on `use Jido.Agent`, because ordering matters for middleware and the top-level option preserves it cleanly.

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent,
    middleware: [
      MyApp.AuthMiddleware,
      Jido.Plugins.FSM,
      MyApp.LoggingMiddleware
    ]

  agent do
    name "support"
    path :domain
    schema [counter: [type: :integer, default: 0]]
  end

  slices do
    slice :memory, Jido.Slices.Memory
    slice :thread, Jido.Slices.Thread
    slice :identity, Jido.Slices.Identity do
      options profile_default: %{age: 0, origin: :spawned}
    end
    slice :fsm, Jido.Plugins.FSM do
      options states: [:idle, :working, :done]
    end
  end

  signal_routes do
    route "support.work", MyApp.WorkAction
  end
end
```

The agent's `slices do … end` block is the **single source of truth** for path-to-slice binding on this agent. The slice module no longer declares `path :memory` itself — the agent does, when it mounts the slice. Path is set per-mount, not per-module. (This also means the same slice module can be mounted at different paths on different agents — a flexibility the current model does not have.)

Plugins (`Jido.Plugins.FSM`, `Jido.Pod.Plugin`, etc.) are slice modules in the `slices do … end` block — same `slice :path, Module do options [...] end` form sets their path and options. There is no separate `plugins do … end` section.

When a plugin also has middleware behaviour, it **additionally** appears in the top-level `middleware: [...]` list. Note `Jido.Plugins.FSM` in the example above: it is registered as a slice (for path + options) *and* listed in `middleware:` (for ordering in the wrap chain). The two registrations cooperate — the slice form configures the plugin's state/path, the middleware list orders its middleware contribution among other middlewares.

Middleware **stays a top-level `use Jido.Agent, middleware: […]` option**. Order is meaningful for middleware (it determines the wrap chain), and a flat ordered list is the right shape. Pure middleware (no slice state) belongs only in this list, never in `slices do … end`.

If a plugin (or slice) ships a typed DSL section the user wants to call into directly (the `Jido.Slice.Extension`-style host section), the plugin module also goes on `use Jido.Agent, extensions: […]`. That mechanism **stays** — it is the channel by which a slice contributes a configuration DSL block to the host agent. It is no longer the channel for slice/plugin enumeration.

Concrete example: `Jido.AI.ReAct` ships a `react do … end` host section for typed configuration. Today it is registered as `extensions: [{Jido.AI.ReAct, [model: "...", tools: [...], …]}]` (tuple form, options inline). After this refactor:

```elixir
defmodule MyApp.MathAgent do
  use Jido.Agent, extensions: [Jido.AI.ReAct]

  agent do
    name "math"
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [Jido.AI.TestActions.TestAdd]
    system_prompt "You are precise."
    max_iterations 4
    max_tokens 256
    temperature 0.0
  end

  slices do
    slice :ai, Jido.AI.ReAct
  end
end
```

`extensions: [Jido.AI.ReAct]` opens the `react do … end` DSL section. The user fills it in with typed fields (autocompleted, schema-validated). The `slices do slice :ai, Jido.AI.ReAct end` line mounts ReAct's slice at path `:ai`. Options that today live in the tuple form move into the typed DSL section. The single `extensions:` registration enables the DSL; the `slices do … end` registration mounts the slice. The two roles are separated — neither mechanism leaks into the other.

Each action within a slice's namespace inherits the slice's path on this agent: `Jido.Slices.Memory.Actions.PutInSpace` resolves to `:memory` because the agent declares `slice :memory, Jido.Slices.Memory` and `PutInSpace` lives under `Jido.Slices.Memory.Actions.*`. No `path :memory` declaration on the action. (Resolution mechanism — by namespace prefix, by signal-route owner, or by some explicit "this action belongs to slice X" link — is the design choice covered in §Resolution below.)

## What moves where

| Today | Target |
|---|---|
| `use Jido.Agent, extensions: [Jido.Memory.Slice, Jido.SomePlugin, MyMiddleware]` flat list classified by `WalkExtensions` | `use Jido.Agent, middleware: [MyMiddleware, Jido.SomePlugin]` (middleware-shaped plugins also appear here for ordering) + `slices do … end` block (slices and plugins both registered here for path + options) |
| `slice do path :memory end` inside `Jido.Memory.Slice` | path declared in agent's `slices do slice :memory, … end` (slice DSL drops `path`) |
| `action do path :memory end` inside every `Jido.Memory.Actions.*` | path inferred at compile/runtime from slice mount; action DSL drops the redundant `path` |
| `plugin do path :fsm end` inside `Jido.Plugins.FSM` | path declared in agent's `slices do slice :fsm, Jido.Plugins.FSM end` (plugin DSL drops `path` — plugins mount via the same `slice` macro) |
| `{Jido.SomePlugin, %{opt: 1}}` tuple form in `extensions:` | `slice :name, Jido.SomePlugin do options opt: 1 end` |
| `extensions: […]` mixed list of slices + plugins + middleware | `extensions:` is **only** for plugin/slice modules whose typed DSL section the user wants to call into (the `Jido.Slice.Extension` host-section mechanism). Slice/plugin enumeration moves entirely into `slices do … end` |
| `default_slices: %{memory: false}` override | unchanged in spirit — likely becomes `slices do slice :memory, false end` or stays as the override mechanism |

## Resolution mechanism (open design point)

`__resolve_slice_path__/1` needs to consult the agent's slice mounts. Two viable strategies:

1. **Namespace-prefix match.** At compile time, the agent's `slices do … end` walker emits a lookup table `%{Jido.Slices.Memory => :memory, Jido.Slices.Memory.Actions.PutInSpace => :memory, …}`. `__resolve_slice_path__/1` looks up the action's module first, then the action's namespace prefix, then falls back to agent path. Cheap to compute; brittle if action modules live outside the slice's namespace.
2. **Signal-route owner.** The agent's slices contribute their `signal_routes` at compile time, and the slice that routes to a given action is the slice that owns it. Path = that slice's mount path. More precise; requires the action be referenced from a slice route at compile time (custom test actions wouldn't be).

The cleanest answer is probably **explicit declaration on the slice's `signal_routes`** (the slice already enumerates its actions there) plus a "test fixture" escape valve where ad-hoc test actions can still declare `path :foo` directly. Decide during planning.

## Dependencies / scope

### DSL surface

- Add a single `slices` section to `Jido.Dsl.Agent` (slices and plugins both mount here — there is no separate `plugins do … end`). Update `Jido.Dsl.Agent.Transformers.WalkExtensions` (or replace it) with new transformers that read this section.
- `middleware:` keeps its current shape as a top-level `use Jido.Agent` option (ordered list).
- `__resolve_slice_path__/1` (in `lib/jido/dsl/agent/transformers/generate_accessors.ex`) rewrite per §Resolution.
- Drop the `path:` field from `Jido.Dsl.Slice` (the slice DSL definition itself). Slices stop having an opinion about their mount path; the agent assigns it.
- Drop the `path:` field from `Jido.Dsl.Action` (`lib/jido/dsl/action.ex:30-34`). Actions never carry a path themselves.
- Drop the `path:` field from `Jido.Dsl.Plugin`. Plugins are mounted with paths the same way slices are (via the `slice` entity in `slices do … end`).
- The `Jido.Slice.Extension` host-section mechanism stays — it is the channel for slices/plugins that *also* want to surface a typed DSL section on the agent. But it is no longer the channel for path overrides; that moves into the `slices do … end` mount declaration.

### Strip every `path :foo` declaration

`git grep -nE '^[[:space:]]*path :' lib/` returns the full list. As of this writing:

| File | Line | Why it goes |
|---|---|---|
| `lib/jido/memory/slice.ex` | 57 | slice declares own path |
| `lib/jido/identity/slice.ex` | 37 | slice declares own path |
| `lib/jido/thread/slice.ex` | (similar) | slice declares own path |
| `lib/jido/memory/actions/{ensure,put_in_space,put_space,update_space,ensure_space,delete_space,delete_from_space,append_to_space}.ex` | various | redundant with slice |
| `lib/jido/identity/actions/{ensure,update_profile,evolve}.ex` | various | redundant with slice |
| `lib/jido/thread/actions/{ensure,append,clear}.ex` | various | redundant with slice |
| `lib/jido/pod/plugin.ex` | 38 | plugin declares own path |
| `lib/jido/pod/bus_plugin.ex` | 57 | plugin declares own path |
| `lib/jido/pod/actions/{mutate,mutate_progress}.ex` | 10, 13 | redundant with plugin |
| `lib/jido/pod/bus_plugin/{auto_subscribe_child,auto_unsubscribe_child}.ex` | 22, 18 | redundant with plugin |
| `lib/jido/plugin/fsm.ex` | 71 | plugin declares own path |
| `lib/jido/plugin/fsm/transition.ex` | 15 | redundant with plugin |
| `lib/jido/plugin/requirements.ex` | 17 | doc example — update |
| `lib/jido/agent.ex` | 64 | doc example — update |
| `lib/jido/igniter/templates.ex` | 34, 90 | code-gen template — update so generated agents emit `slices do … end` |

The agent's own `path :domain` declaration in its `agent do … end` block **stays** — that is the agent's own state slice (where its `schema [...]` fields live), conceptually distinct from mounted slices.

### Call-site updates

- Every in-tree agent declaration (`Jido.AI.Agent`, example tests, livebooks) updates to use the new `slices do … end` / `plugins do … end` blocks instead of `extensions: [...]` flat list.
- Every place that constructs an action result expecting the old path resolution (none in `lib/`, but check `test/`) updates if needed.
- `default_slices` override mechanism fits the new shape — likely `slices do slice :memory, false end` for disable, `slices do slice :memory, MyCustomMemorySlice end` for replacement, and the agent's `:default_slices` opt becomes the package-level defaults applied unless the agent's `slices do … end` overrides.

### Tooling

- Regen Spark cheat sheets (`mix spark.cheat_sheets`).
- Refresh `guides/migration-spark-dsl.md` and `guides/storage.md` to use the new DSL throughout. The current guide is itself a migration doc for the previous DSL flip — needs a follow-up section or a wholesale rewrite.
- Add an ADR amendment (or new ADR) capturing the §Resolution decision.

## Out of scope

- Action-level cleanup beyond removing the redundant `path` declaration. (No new return shape, no signature change.)
- Renaming `lib/jido/<slice>/` directories — that is [task 0044](0044-move-rename-memory-slice.md) onwards.
- Changing the `Jido.Agent.SliceUpdate` multi-slice escape hatch.
- Per the "NO LEGACY ADAPTERS" rule (`guides/tasks/README.md`): no shim that accepts both the old `extensions: […]` flat list and the new `slices do … end` block. Rewrite every callsite.

## Acceptance

- `git grep -nE 'path :(memory|identity|thread)\b' lib/` returns zero hits in `lib/jido/<slice>/slice.ex` and zero hits in `lib/jido/<slice>/actions/*.ex`. (Hits remain in test fixtures that are ad-hoc actions, if the design keeps the `path :foo` escape valve.)
- Every in-tree agent (`Jido.AI.Agent`, `lib/jido/agents/*.ex`, every test inline `defmodule …Agent`) declares its slices via `slices do … end`. Zero uses of `extensions: [Jido.Memory.Slice, …]` or `{Module, opts}` tuple form.
- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix test --include e2e` clean.
- Cheat sheets regenerated and committed.

## Risks

- **Resolution mechanism is the load-bearing design choice.** Picking namespace-prefix match is simple but brittle; picking signal-route ownership is precise but more compile-time machinery. Worth a short ADR (or amendment to ADR 0025) before the implementation PR.
- **`default_slices` override surface.** Today users disable a default slice with `default_slices: %{memory: false}` on `use Jido.Agent`. The new shape should keep that mechanism working, ideally via the `slices do slice :memory, false end` form or by leaving `default_slices:` alone as the override channel. Decide during planning.
- **Migration churn for in-tree livebooks and example tests.** Every agent declaration changes shape. Scope the touch list during planning so the PR isn't a "rename in 60 files" surprise.
