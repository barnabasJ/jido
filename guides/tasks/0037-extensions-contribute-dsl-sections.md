---
name: Task 0037 — Slices / plugins / middleware contribute DSL sections to host agents (Ash-style extensions)
description: Make `use Jido.Agent, extensions: [Jido.AI.ReAct, Jido.Memory.Slice]` unlock per-extension DSL blocks (`react do … end`, `memory do … end`) on the host agent. Each slice / plugin module declares the section it wants to contribute via the `Jido.Slice.Extension` macro (`use Jido.Slice.Extension, host_section: :react`); the macro auto-translates the slice's `config_schema/0` into a Spark section schema. Task 0034's `WalkExtensions` transformer reads the typed-block config out of the host's DSL state — there's no separate "merge contributed" transformer in this task. `Jido.AI.ReAct` is the canonical example and migrates as part of this task. **Also deletes every transitional helper left in tree from tasks 0033 – 0036**: `Jido.Dsl.Agent.LegacyTranslator`, the dead `@agent_config_schema` Zoi schema, and the `# task 0034 / 0035` qualifiers on moduledocs. After this commit the codebase reads as if Spark + the per-DSL info modules were the surface from day one.
---

# Task 0037 — Slices contribute DSL sections to host agents

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §4 (the typed-section contribution mechanism layered on top of §3's unified extensions list).
- Depends on: [task 0034](0034-port-jido-agent-to-spark.md) (the host agent DSL exists), [task 0035](0035-port-slice-plugin-middleware-to-spark.md) (each slice has a Spark DSL of its own to riff on), [task 0036](0036-port-action-and-sensor-to-spark.md) (so the tree is green).
- Blocks: [task 0038](0038-docs-and-cleanup.md).
- Leaves tree: **green**.

## Context

After task 0034 the agent DSL has host-owned sections (`agent`,
`signal_routes`, `schedules`) and the `extensions: [...]` keyword on
`use Jido.Agent` registers contributing modules. After task 0035
every slice / plugin / middleware module has its own Spark DSL
describing its own surface. What's still missing is the bridge:
each registered extension needs to actually contribute a typed
block (`react do … end`, `memory do … end`, `retry do … end`) to
the host. Without it, the user has no way to configure an
extension's options at the host's compile site.

ADR 0023 §3 — §4 calls for that bridge: each module registered in
`extensions: [...]` is itself a `Spark.Dsl.Extension` and Spark adds
its sections to the host. The user gets a per-extension typed block
with autocomplete, formatter awareness, and a per-extension docs
page.

## Goal

After this commit:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent, extensions: [Jido.AI.ReAct, Jido.Memory.Slice]

  agent do
    name "support"
    path :domain
  end

  signal_routes do
    route "user.created", MyApp.HandleUserCreated
  end

  # contributed by Jido.AI.ReAct
  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [MyApp.Actions.LookupOrder, MyApp.Actions.RefundOrder]
    system_prompt "You are a support agent."
    max_iterations 5
  end

  # contributed by Jido.Memory.Slice
  memory do
    backend MyApp.MemoryBackend
    namespace :support
  end
end
```

`MyApp.SupportAgent.slice_instances/0` returns exactly the same
shape it would return for the explicit-form

```elixir
slices do
  slice Jido.AI.ReAct, model: "…", tools: […], …
  slice Jido.Memory.Slice, backend: MyApp.MemoryBackend, namespace: :support
end
```

— i.e. both forms feed the same downstream machinery from task 0034.
The user picks whichever reads better for their codebase.

## Files to modify

### `lib/jido/dsl/agent.ex`

Add an extension-discovery transformer that runs before the existing
transformers:

1. Read the `extensions:` keyword passed to `use Jido.Agent`. (Stored
   on the host module as `@jido_user_extensions` per task 0034.)
2. For each extension module, call `module.spark_dsl_extensions/0`
   to discover any sections it declares as `host_contribution: true`
   (a new metadata flag — see "Contribution metadata" below).
3. Register those sections on the host's DSL **dynamically**, so the
   user's subsequent `react do … end` block parses against the
   contributed section's schema.

Spark provides this via `Spark.Dsl.Extension.add_extensions/2`. The
transformer feeds `Jido.AI.ReAct`, `Jido.Memory.Slice`, etc. through
that hook so their contributed sections are discoverable on the host.

Once the host is fully parsed, task 0034's `WalkExtensions`
transformer walks the `extensions: [...]` keyword list and, for each
module, reads its typed section's validated values out of the DSL
state via `Spark.Dsl.Extension.get_opt(dsl_state, [section_name])`.
The kind classification (slice / plugin / middleware) comes from
the module's markers; the `extensions: [...]` keyword-list order
becomes the chain order. There is no `as:` keyword on entries by
default — the `{Module, as: :slice}` override is a rare escape
hatch used only when forcing a `use Jido.Plugin` module to mount
slice-only.

If a module is listed in `extensions: [...]` but its typed block is
omitted on the host, the section's schema defaults are used (and a
schema with required fields raises `CompileError` at the host's
compile time). If a module's section is provided but the module is
not registered, Spark raises an unknown-section error at parse time
— the user either adds it to `extensions: [...]` or removes the
block.

### `lib/jido/slice/extension.ex` (new)

A small helper macro that lets a slice author opt into the host
contribution with one line:

```elixir
defmodule Jido.Slice.Extension do
  @moduledoc """
  `use Jido.Slice.Extension, host_section: :react` makes the slice
  available as a Jido.Agent extension that contributes a `react do
  … end` section to the host module's DSL. The section's schema is
  derived from the slice's `config_schema/0`.
  """

  defmacro __using__(opts) do
    section_name = Keyword.fetch!(opts, :host_section)

    quote do
      def __jido_host_section__, do: unquote(section_name)

      def __jido_host_contribution__ do
        %Spark.Dsl.Section{
          name: unquote(section_name),
          schema: Jido.Slice.Extension.schema_from_config_schema(__MODULE__)
        }
      end
    end
  end

  @doc """
  Translate a slice's Zoi `config_schema/0` into a Spark / NimbleOptions
  schema for use as a `host_contribution` section.

  This handles the common cases (string, atom, integer, list, map);
  for unsupported Zoi shapes, the slice author can override
  `__jido_host_contribution__/0` directly to write the schema by hand.
  """
  def schema_from_config_schema(module) do
    case module.config_schema() do
      nil -> []
      schema -> Jido.Slice.Extension.SchemaTranslate.translate(schema)
    end
  end
end
```

`Jido.Slice.Extension.SchemaTranslate.translate/1` walks a Zoi struct
schema and produces a NimbleOptions keyword list. v1 covers the
shapes our in-tree slices use (string, atom, integer, pos_integer,
boolean, list, map, any). Anything more exotic falls back to `:any`
and the slice author overrides `__jido_host_contribution__/0`
manually.

### `lib/jido/ai/react.ex`

The canonical example slice migrates to the contribution shape:

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

  actions do
    action Jido.AI.ReAct.Action.Step
    action Jido.AI.ReAct.Action.Ask
  end

  signal_routes do
    route "ai.react.ask", Jido.AI.ReAct.Action.Ask
    route "ai.react.step", Jido.AI.ReAct.Action.Step
  end

  use Jido.Slice.Extension, host_section: :react
end
```

After this commit a host agent that declares `extensions: [Jido.AI.ReAct]`
gets the typed `react do … end` block.

### `lib/jido/identity/slice.ex`, `lib/jido/memory/slice.ex`, `lib/jido/thread/slice.ex`

Each framework-default slice gets the same one-line contribution
declaration:

```elixir
use Jido.Slice.Extension, host_section: :identity   # or :memory, :thread
```

The framework's default-slices machinery (per task 0032) uses the
same path — extensions land via `extensions: […]` if the host wants
typed sections, or via the existing `default_slices:` /
`slices: do … end` slot if the host doesn't.

### `lib/jido/dsl/agent/transformers/discover_extensions.ex` (new)

```elixir
defmodule Jido.Dsl.Agent.Transformers.DiscoverExtensions do
  use Spark.Dsl.Transformer

  def before?(_), do: true   # run before NormalizeSlices

  def transform(dsl_state) do
    extensions = Spark.Dsl.Transformer.get_persisted(dsl_state, :jido_user_extensions, [])

    Enum.reduce_while(extensions, {:ok, dsl_state}, fn ext, {:ok, acc} ->
      case extension_section(ext) do
        nil -> {:cont, {:ok, acc}}
        section ->
          case Spark.Dsl.Extension.add_section(acc, section) do
            {:ok, new_state} -> {:cont, {:ok, new_state}}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp extension_section(module) do
    if function_exported?(module, :__jido_host_contribution__, 0) do
      module.__jido_host_contribution__()
    end
  end
end
```

(Pseudocode — Spark's exact transformer API for adding sections post-parse
varies; the transformer may need to register the section *before* the
host parses, not after. Resolve at implementation time.)

### Read path: task 0034's `WalkExtensions` reads typed-section config

There is no separate "merge contributed" transformer. Task 0034
ships `Jido.Dsl.Agent.Transformers.WalkExtensions`, which walks the
`extensions: [...]` keyword list, classifies each module by marker,
and reads its typed-section config out of the DSL state via
`Spark.Dsl.Extension.get_opt(dsl_state, [section_name], …)`. The
section name comes from the module's `__jido_host_section__/0`
marker emitted by the `Jido.Slice.Extension` macro above.

The pseudocode in `WalkExtensions` (per task 0034) reads roughly:

```elixir
def transform(dsl_state) do
  extensions = Spark.Dsl.Transformer.get_persisted(dsl_state, :spark_extensions, [])

  for module <- jido_extensions(extensions), reduce: dsl_state do
    acc -> classify_and_register(acc, module)
  end
end

defp classify_and_register(dsl_state, module) do
  section = module.__jido_host_section__()
  config  = Spark.Dsl.Transformer.get_options(dsl_state, [section]) || %{}
  kind    = infer_kind(module)              # :slice | :plugin | :middleware

  case kind do
    :slice      -> append(dsl_state, :slices,     %Jido.Slice.Instance{module: module, config: config})
    :plugin     -> append(dsl_state, :plugins,    %Jido.Plugin.Instance{module: module, config: config})
    :middleware -> append(dsl_state, :middleware, {module, config})
  end
end
```

Order is preserved across the keyword list. Task 0037's
contribution to this flow is purely the `Jido.Slice.Extension`
macro that lets a module mark itself as contributing a section
named `X` whose schema is auto-translated from its
`config_schema/0`.

## Files to create

- `lib/jido/slice/extension.ex`
- `lib/jido/slice/extension/schema_translate.ex`
- `lib/jido/dsl/agent/transformers/discover_extensions.ex`
- `test/jido/dsl/extension_test.exs`
- `test/jido/dsl/extension_react_test.exs` — uses Mimic to stub
  `ReqLLM.Generation.generate_text/3` and exercises a host agent
  declaring `extensions: [Jido.AI.ReAct]` with a `react do … end`
  block end-to-end.
- `test/jido/dsl/extension_compose_test.exs` — host agent with
  multiple contributing extensions, asserts they all merge and
  the kind inference resolves correctly per module.
- `test/jido/dsl/extension_order_test.exs` — host agent declaring
  `extensions: [Plugin1, Middleware1, Plugin2]` with each typed
  block filled in, asserts the resulting middleware-chain
  composition matches the keyword-list order.

## Cleanup of legacy / migration helpers

Tasks 0033 – 0036 left a few transitional helpers in tree so the
pod surface kept compiling while the agent surface ported to Spark.
With the contribution mechanism in place, every host module can
declare its surface natively and we can delete the transitional
pieces. **No legacy / migration helpers remain after this task.**

### Migrate `lib/jido/pod.ex` to the sectioned DSL

`Jido.Pod.__using__/1` currently reads its keyword opts and feeds
them through `Jido.Dsl.Agent.LegacyTranslator.quoted_agent_use/1`,
which converts the keyword form into the new sectioned blocks. That
shim was scaffolding — once Pod itself uses the sectioned form
directly (`use Jido.Pod` plus `pod do … end`, `agent do … end`,
`signal_routes do … end`, etc.), the shim has no callers.

Concretely:

1. Make `Jido.Pod` a `Spark.Dsl` host (`use Spark.Dsl,
   default_extensions: [extensions: [Jido.Dsl.Pod]]`) with its own
   typed `pod do … end` section for `topology:` (and any other
   pod-specific options). Re-export the agent / signal_routes /
   schedules sections so the user writes a single sectioned module.
2. Migrate every in-tree `use Jido.Pod, …` site (lib/ and test/) to
   the sectioned form.
3. Drop the `Jido.Pod.__using__/1` body's call to `LegacyTranslator`
   and the `extensions: [...] = …` resolution; the Spark host gives
   us all of that for free.

### Files to delete

- **`lib/jido/dsl/agent/legacy_translator.ex`** — only consumer was
  `Jido.Pod.__using__/1`. Once Pod is on the sectioned DSL, this
  module has no callers and is removed.
- **`lib/jido/agent.ex` `@agent_config_schema` Zoi schema and
  `config_schema/0`** (lines ~212 – 285) — the agent now declares
  its surface via `Jido.Dsl.Agent`'s section schema; the standalone
  Zoi schema and the `Jido.Agent.config_schema/0` accessor are dead.
  `Spark.Dsl.Extension.get_opt/3` and the per-DSL info modules are
  the only supported way to read agent metadata.

### Stale doc references to remove

- `lib/jido/agent.ex` moduledoc — remove the `(Spark DSL — task
  0034)` qualifier on the example heading and the "Per-extension
  typed sections … land in task 0035" paragraph; both are
  transitional notes.
- `lib/jido/dsl/agent.ex` moduledoc — remove the "Per-extension
  typed sections (e.g. `memory do … end`, `slack do … end`) arrive
  in task 0035 once `use Jido.Slice` / `use Jido.Plugin` /
  `use Jido.Middleware` themselves register Spark sections" note.
- `lib/jido/dsl/agent/verifiers/no_section_name_collisions.ex`
  moduledoc — remove the "For task 0034 the registered extensions
  don't yet contribute their own typed sections — they will once
  task 0035 lands" note. By task 0037 they do.

The verifier itself stays — it just now describes how it
*currently* behaves, not what's coming.

### Files to delete (summary)

- `lib/jido/dsl/agent/legacy_translator.ex`

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean.
- **No legacy / migration helpers remain.** `git grep` for the
  following must return zero in `lib/`:

      LegacyTranslator
      legacy_translator
      @agent_config_schema
      Jido.Agent.config_schema(

  Tree reads as if Spark + the per-DSL info modules were the
  surface from day one — no transitional shims.

The new tests cover:

1. **Single contribution.** `use Jido.Agent, extensions: [Jido.AI.ReAct]`
   plus a `react do model "…"; tools […] end` block produces a
   `slice_instances/0` output containing the ReAct slice with the
   typed-block config.
2. **Multiple contributions compose.** `extensions: [Jido.AI.ReAct,
   Jido.Memory.Slice]` plus both `react do … end` and `memory do …
   end` blocks merges cleanly; both slices register at their
   respective `path()`s.
3. **Override form.** `extensions: [{Jido.AI.ReAct, as: :slice}]`
   mounts ReAct slice-only (skipping its middleware half). The
   typed `react do … end` block still parses against the slice's
   schema. A `{BareSlice, as: :plugin}` raises with a clear "no
   `__jido_plugin__/0` marker" error.
4. **Bad config rejected at compile time.** `react do model 42 end`
   (wrong type) raises a Spark validation error citing the
   contributing extension.
5. **Path collision** between a contributed slice and the agent's
   own `path:` raises `UniquePaths` exactly as before — the
   downstream verifier doesn't care which transformer added the
   slice.
6. **Schema translate fallback.** A slice with a `config_schema`
   shape `Jido.Slice.Extension.SchemaTranslate` doesn't recognize
   compiles cleanly with the section schema set to `[type: :any]`,
   and the slice author can override
   `__jido_host_contribution__/0` to write a richer schema.
7. **Order preservation through contribution.** `extensions:
   [PluginA, MiddlewareB, PluginC]` produces a middleware chain
   that wraps in exactly that order: `PluginA → MiddlewareB →
   PluginC → core`. A regression test composes three trivial
   middleware halves that append to a list passed via ctx, and
   asserts the list order matches the declaration order.

## Out of scope

- **Plugin contributions.** A `use Jido.Plugin` module that wants to
  contribute *both* a slice section *and* additional middleware
  options can do so via the same hook (it inherits `Jido.Slice.Extension`
  through the `use Jido.Plugin` shim). v1 ships the slice path; if
  a plugin needs a separate middleware section we add a
  `host_middleware_section:` opt to `Jido.Slice.Extension` in a
  follow-up.
- **Multi-instance contributed sections.** A user wanting two
  `react do … end` blocks (one per ReAct instance with different
  models) is out of scope — Spark sections are singleton by default,
  and the slice author would need to switch to an entity-list
  shape (`reacts do react :primary, model: "…"; react :secondary,
  model: "…" end`). Add when a concrete need surfaces.
- **Igniter generators that scaffold an extension.** Out of scope.
- **Cheat-sheet / migration guide writing.** Task 0038.

## Risks

- **Spark API shape.** The exact shape of "register a section
  dynamically per host" varies across Spark minor versions. v2.2+
  supports it via `Spark.Dsl.Extension.add_extensions/2` on the
  parser side; confirm during implementation.
- **Schema-translate completeness.** `SchemaTranslate` covers the
  shapes our in-tree slices use. Out-of-tree slices with exotic Zoi
  shapes need to override `__jido_host_contribution__/0` manually.
  Document the override path clearly in `Jido.Slice.Extension`'s
  moduledoc.
- **Section name collisions.** Two extensions both contributing a
  `:react` section would silently clobber each other. The
  `DiscoverExtensions` transformer detects collisions and raises
  `CompileError` with the colliding extension modules named.
- **Default-slices integration.** Task 0032's `default_slices:` /
  `Jido.Agent.DefaultSlices` continues to work for slices that
  attach without a user-typed section — the discovery transformer
  ignores extensions that came in via default-slices, since they
  weren't named in `extensions: […]`.
