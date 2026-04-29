---
name: Task 0041 — Extensions contribute typed DSL sections to host agents; Pod migration; delete LegacyTranslator + `@agent_config_schema`
description: Build the contribution mechanism on top of the cleaned-up slice surface. `use Jido.Slice.Extension, host_section: :react` makes the slice contribute a `react do … end` typed block to host agents that list it in `extensions: […]`. The contributed section's schema includes a built-in `path:` field (default `slice.path()`) so the host can rename the mount path inline (the field shape is established in [task 0038](0038-agent-dsl-optional-path-and-extension-path-override.md); this task wires it through the contribution macro). Schema-translate fallback for slices with rich Zoi `config_schema/0` shapes; out-of-tree slices with exotic shapes override `__jido_host_contribution__/0` manually. Migrates `Jido.AI.ReAct` + the now-real `Jido.{Memory,Identity,Thread}.Slice` (per [task 0039](0039-slices-must-declare-schema-and-routes.md)) to opt into the macro. Migrates `Jido.Pod` to its own Spark DSL host with a `Jido.Dsl.Pod` extension; every in-tree `use Jido.Pod, …` keyword-form site rewrites. Deletes `Jido.Dsl.Agent.LegacyTranslator`, `Jido.Agent`'s `@agent_config_schema` Zoi schema, and the `Jido.Agent.config_schema/0` accessor. Strips the transitional `(task 003N)` qualifiers from moduledocs. After this commit the codebase reads as if Spark + the per-DSL Info modules were the surface from day one.
---

# Task 0041 — Extensions contribute typed DSL sections; Pod migration; legacy deletes

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §4 (typed-section contribution mechanism layered on top of §3's unified extensions list).
- Depends on: [task 0037](0037-slice-dsl-cleanup.md), [task 0038](0038-agent-dsl-optional-path-and-extension-path-override.md), [task 0039](0039-slices-must-declare-schema-and-routes.md), [task 0040](0040-use-spark-tooling-everywhere.md).
- Blocks: [task 0042](0042-docs-and-cleanup.md).
- Leaves tree: **green**.

## Context

Tasks 0033–0040 leave us with: every `use Jido.X` site is on Spark;
the slice DSL is tight (shape + routes minimum, no `actions do`,
no `singleton:`); the agent DSL allows path-less agents and per-extension
`path:` override; introspection is uniform via Info modules. What's
still missing is the bridge from "module listed in `extensions: [...]`"
to "user gets a typed `react do … end` block on the host with
autocomplete and validation."

ADR 0023 §4 calls for that bridge: each module registered in
`extensions: [...]` exposes a host-contributed section whose schema is
derived from the module's `config_schema/0`. The user gets one typed
block per extension on their host agent.

## Goal

After this commit:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent, extensions: [Jido.AI.ReAct, Jido.Memory.Slice]

  agent do
    name "support"
    # no own slice — the agent composes ReAct + Memory.
  end

  signal_routes do
    route "user.created", MyApp.HandleUserCreated
  end

  # contributed by Jido.AI.ReAct
  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [MyApp.Actions.LookupOrder]
    system_prompt "You are a support agent."
    max_iterations 5
  end

  # contributed by Jido.Memory.Slice; rename mount path
  memory do
    path :short_term
  end
end
```

`MyApp.SupportAgent.slice_instances/0` returns:

- a `Jido.AI.ReAct` slice mounted at `:ai` with the typed-block config
  applied, and
- a `Jido.Memory.Slice` slice mounted at `:short_term` (renamed via
  the contributed section's `path:` field).

The host's own slice is absent — `agent do` declared no `path:` and
no `schema:` ([task 0038](0038-agent-dsl-optional-path-and-extension-path-override.md)).

## Files to modify

### `lib/jido/slice/extension.ex` (new)

```elixir
defmodule Jido.Slice.Extension do
  @moduledoc """
  Opt a slice into being a host-agent extension that contributes
  one typed DSL block (`<host_section> do … end`) to host modules
  that list it in `extensions: [...]`.

      defmodule MyApp.MemorySlice do
        use Jido.Slice
        slice do … end
        signal_routes do … end

        use Jido.Slice.Extension, host_section: :memory
      end

  The contributed section's schema is derived from the slice's
  `config_schema/0` via `Jido.Slice.Extension.SchemaTranslate`.
  Slices with richer Zoi shapes that the translator can't handle
  override `__jido_host_contribution__/0` manually.
  """

  defmacro __using__(opts) do
    section_name = Keyword.fetch!(opts, :host_section)

    quote bind_quoted: [section_name: section_name] do
      @doc false
      @spec __jido_host_section__() :: atom()
      def __jido_host_section__, do: unquote(section_name)

      @doc false
      @spec __jido_host_contribution__() :: Spark.Dsl.Section.t()
      def __jido_host_contribution__ do
        Jido.Slice.Extension.build_section(__MODULE__, unquote(section_name))
      end

      defoverridable __jido_host_contribution__: 0
    end
  end

  @doc false
  def build_section(module, section_name) do
    schema = base_schema(module)
    %Spark.Dsl.Section{
      name: section_name,
      describe: section_describe(module),
      schema: schema
    }
  end

  defp base_schema(module) do
    base_path = Jido.Dsl.Slice.Info.path(module)
    user_schema =
      case maybe_config_schema(module) do
        nil -> []
        zoi -> Jido.Slice.Extension.SchemaTranslate.translate(zoi)
      end

    [
      path: [
        type: :atom,
        default: base_path,
        doc:
          "Slice mount path on this host. Defaults to the slice's declared `path()`. " <>
            "Override to rename the slice's slot in `agent.state`."
      ]
    ] ++ user_schema
  end

  defp maybe_config_schema(module) do
    case Jido.Dsl.Slice.Info.config_schema(module) do
      nil -> nil
      [] -> nil
      schema -> schema
    end
  end

  defp section_describe(module) do
    Jido.Dsl.Slice.Info.description(module) ||
      "Configuration block contributed by #{inspect(module)}."
  end
end
```

### `lib/jido/slice/extension/schema_translate.ex` (new)

```elixir
defmodule Jido.Slice.Extension.SchemaTranslate do
  @moduledoc """
  Translates a slice's Zoi `config_schema/0` into a Spark.Options-compatible
  keyword-list schema for use as a host-contribution section.

  v1 covers the in-tree slice shapes:

    * `Zoi.string/1`     -> `:string`
    * `Zoi.atom/1`       -> `:atom`
    * `Zoi.integer/1`    -> `:integer` (with `:pos_integer` for positive constraints)
    * `Zoi.boolean/1`    -> `:boolean`
    * `Zoi.list/2`       -> `{:list, inner_type}`
    * `Zoi.map/1`        -> `:map`
    * `Zoi.any/1`        -> `:any`
    * `Zoi.optional/1`   -> drops `required: true`
    * `Zoi.default/2`    -> `default: value`

  Anything more exotic falls back to `:any`. Slice authors with
  richer shapes override `__jido_host_contribution__/0` manually
  to write the schema by hand.
  """

  @spec translate(term()) :: keyword()
  def translate(%Zoi.Types.Object{fields: fields}) do
    Enum.map(fields, fn {key, field_schema} ->
      {key, translate_field(field_schema)}
    end)
  end

  def translate(_other), do: []

  defp translate_field(%{__struct__: type} = field) do
    base = base_type(type)
    base
    |> maybe_default(field)
    |> maybe_required(field)
    |> maybe_doc(field)
  end

  # … (one helper per Zoi struct variant the in-tree slices use)

  defp base_type(Zoi.Types.String), do: [type: :string]
  defp base_type(Zoi.Types.Atom), do: [type: :atom]
  defp base_type(Zoi.Types.Integer), do: [type: :integer]
  defp base_type(Zoi.Types.Boolean), do: [type: :boolean]
  defp base_type(Zoi.Types.Map), do: [type: :map]
  defp base_type(Zoi.Types.Any), do: [type: :any]
  defp base_type(_), do: [type: :any]

  defp maybe_default(opts, %{default: default}) when not is_nil(default),
    do: Keyword.put(opts, :default, default)
  defp maybe_default(opts, _), do: opts

  defp maybe_required(opts, %{optional: true}), do: opts
  defp maybe_required(opts, _), do: opts   # NimbleOptions defaults to optional unless `required: true`

  defp maybe_doc(opts, %{description: doc}) when is_binary(doc),
    do: Keyword.put(opts, :doc, doc)
  defp maybe_doc(opts, _), do: opts
end
```

(Pseudocode — check the actual Zoi struct shapes at implementation
time; the `Zoi.Types.*` modules have the canonical struct
definitions in `deps/zoi/lib/zoi/types/`.)

### `lib/jido/dsl/agent.ex`

Add `Jido.Dsl.Agent.Transformers.DiscoverExtensions` to the
`transformers:` list, *before* `WalkExtensions`:

```elixir
transformers: [
  Jido.Dsl.Agent.Transformers.DiscoverExtensions,
  Jido.Dsl.Agent.Transformers.WalkExtensions,
  Jido.Dsl.Agent.Transformers.MergeSchemas,
  Jido.Dsl.Agent.Transformers.ExpandRoutes,
  Jido.Dsl.Agent.Transformers.ValidateRequirements,
  Jido.Dsl.Agent.Transformers.GenerateAccessors
]
```

### `lib/jido/agent.ex`

Override `Jido.Agent.__using__/1` to inject Spark-extension shadow
modules into the user's `extensions:` keyword list before Spark
processes it:

```elixir
defoverridable __using__: 1

defmacro __using__(opts) do
  user_extensions = Keyword.get(opts, :extensions, []) |> List.wrap()

  shadow_extensions =
    user_extensions
    |> Enum.map(&extract_module/1)
    |> Enum.flat_map(&maybe_shadow_extension/1)

  new_opts =
    Keyword.update(opts, :extensions, shadow_extensions, fn exts ->
      List.wrap(exts) ++ shadow_extensions
    end)

  super(new_opts)
end

defp extract_module(mod) when is_atom(mod), do: mod
defp extract_module({mod, _opts}) when is_atom(mod), do: mod

defp maybe_shadow_extension(mod) do
  if Code.ensure_loaded?(mod) and function_exported?(mod, :__jido_host_extension_module__, 0) do
    [mod.__jido_host_extension_module__()]
  else
    []
  end
end
```

(The shadow extension is a Spark.Dsl.Extension that exposes the
contributed section. Generated alongside the slice module by
`Jido.Slice.Extension.__using__`. See "shadow module" notes below.)

### `lib/jido/dsl/agent/transformers/discover_extensions.ex` (new)

```elixir
defmodule Jido.Dsl.Agent.Transformers.DiscoverExtensions do
  @moduledoc """
  Validates that user-listed extensions don't contribute colliding
  section names. Persists `:jido_contributed_sections` mapping
  `module -> section_name` for `WalkExtensions` to read.
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    extensions = Transformer.get_persisted(dsl_state, :jido_user_extensions, [])

    contributions =
      extensions
      |> Enum.map(&extract_module/1)
      |> Enum.flat_map(fn mod ->
        if function_exported?(mod, :__jido_host_section__, 0) do
          [{mod.__jido_host_section__(), mod}]
        else
          []
        end
      end)

    case detect_collisions(contributions) do
      [] ->
        contributed_sections = Map.new(contributions, fn {section, mod} -> {mod, section} end)
        {:ok, Transformer.persist(dsl_state, :jido_contributed_sections, contributed_sections)}

      collisions ->
        {:error, collision_error(collisions)}
    end
  end

  defp detect_collisions(contributions) do
    contributions
    |> Enum.group_by(fn {section, _mod} -> section end, fn {_, mod} -> mod end)
    |> Enum.filter(fn {_section, mods} -> length(Enum.uniq(mods)) > 1 end)
  end

  defp collision_error(collisions) do
    msg =
      Enum.map_join(collisions, "; ", fn {section, mods} ->
        names = mods |> Enum.uniq() |> Enum.map_join(", ", &inspect/1)
        "section #{inspect(section)} contributed by multiple extensions: #{names}"
      end)

    Spark.Error.DslError.exception(message: "Section name collisions: " <> msg, path: [])
  end

  defp extract_module(mod) when is_atom(mod), do: mod
  defp extract_module({mod, _}) when is_atom(mod), do: mod
end
```

### `lib/jido/dsl/agent/transformers/walk_extensions.ex`

Update `classify/1` to read each module's typed-block config out
of dsl_state via the contributed-sections index:

```elixir
defp classify(dsl_state, entry) do
  {module, opts, as_override} = normalize_entry(entry)
  ensure_module_loaded!(module)

  contributed_sections =
    Transformer.get_persisted(dsl_state, :jido_contributed_sections, %{})

  block_config =
    case Map.get(contributed_sections, module) do
      nil -> %{}
      section_name ->
        Spark.Dsl.Extension.get_opt(dsl_state, [section_name]) |> normalize_to_map()
    end

  {mount_path, block_config} = Map.pop(block_config, :path)

  config = Map.merge(opts |> normalize_to_map(), block_config)

  plugin?     = Spark.Dsl.is?(module, Jido.Plugin)
  slice?      = Spark.Dsl.is?(module, Jido.Slice)
  middleware? = behaves_as_middleware?(module)

  kind = pick_kind(module, plugin?, slice?, middleware?, as_override)

  case kind do
    :slice ->
      decl =
        if mount_path do
          {module, Map.put(config, :__path_override__, mount_path)}
        else
          build_decl(module, config)
        end
      {:slice, SliceInstance.new(decl)}
    …
  end
end
```

The `:__path_override__` key is read by `Jido.Slice.Instance.new/1`
to set the slice's mount path explicitly, bypassing the slice's
own `path()`. Same shape for plugin / middleware extension entries
that opt in.

### `lib/jido/slice/instance.ex`

Honour the `:__path_override__` key when building a `%SliceInstance{}`:

```elixir
def new(slice_declaration) do
  {module, overrides} = normalize_declaration(slice_declaration)

  base_path = Jido.Dsl.Slice.Info.path(module)
  base_name = Jido.Dsl.Slice.Info.name(module)
  resolved_config = Config.resolve_config!(module, Map.delete(overrides, :__path_override__))

  path = Map.get(overrides, :__path_override__, base_path)

  %__MODULE__{
    module: module,
    config: resolved_config,
    path: path,
    name: base_name
  }
end
```

(Manifest is gone after [task 0040](0040-use-spark-tooling-everywhere.md);
fields read directly via Info.)

### Slice migrations

Each in-tree slice that should opt into the contribution
mechanism gets a `use Jido.Slice.Extension, host_section: …`
line:

#### `lib/jido/ai/re_act.ex`

```elixir
defmodule Jido.AI.ReAct do
  use Jido.Slice
  slice do … end
  signal_routes do … end

  use Jido.Slice.Extension, host_section: :react
end
```

#### `lib/jido/identity/slice.ex`

```elixir
use Jido.Slice.Extension, host_section: :identity
```

#### `lib/jido/memory/slice.ex`

```elixir
use Jido.Slice.Extension, host_section: :memory
```

#### `lib/jido/thread/slice.ex`

```elixir
use Jido.Slice.Extension, host_section: :thread
```

#### `lib/jido/pod/plugin.ex`, `lib/jido/pod/bus_plugin.ex`

**Decision:** do not opt these into the contribution mechanism
(the pod plugins are framework-internal — their state is seeded by
`Jido.Pod.BeforeCompile` from the pod's topology, not by user
DSL config; a `pod do … end` block on the user's host would be
confusing). Document the exclusion in each module's moduledoc.

### Pod migration to a Spark DSL host

#### `lib/jido/dsl/pod.ex` (new)

```elixir
defmodule Jido.Dsl.Pod do
  @moduledoc """
  Spark DSL extension for `Jido.Pod`. Adds a `pod do … end` section
  for the topology and pod-specific options. Re-exports the agent /
  signal_routes / schedules sections from `Jido.Dsl.Agent` via
  `add_extensions:` so the user writes a single sectioned module.
  """

  @pod_section %Spark.Dsl.Section{
    name: :pod,
    describe: "Pod topology and runtime options.",
    schema: [
      topology: [
        type: :any,
        default: %{},
        doc: "Map of node names to node specs, or a `%Jido.Pod.Topology{}` struct."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@pod_section],
    add_extensions: [Jido.Dsl.Agent],
    transformers: [Jido.Dsl.Pod.Transformers.ResolveTopology]
end
```

#### `lib/jido/dsl/pod/transformers/resolve_topology.ex` (new)

The current `Jido.Pod.Definition.resolve_topology!/3` runs at
`__using__/1` time. Move it into a transformer that reads the
`pod.topology` value out of `dsl_state`, validates / coerces it
into a `%Jido.Pod.Topology{}`, and persists it as
`:resolved_topology` for `Jido.Pod.BeforeCompile` to read.

#### `lib/jido/pod.ex`

Drop the keyword-translating `__using__/1` body. Make `Jido.Pod` a
Spark host:

```elixir
defmodule Jido.Pod do
  @moduledoc """
  Pod wrapper: a `Jido.Agent` with a canonical topology and a singleton
  pod plugin mounted under `:pod`.

      defmodule MyApp.Fulfillment do
        use Jido.Pod

        agent do
          name "fulfillment"
        end

        pod do
          topology %{
            warehouse: %{agent: MyApp.Warehouse, manager: :fulfillment_warehouse, activation: :eager},
            shipping:  %{agent: MyApp.Shipping,  manager: :fulfillment_shipping,  activation: :eager}
          }
        end
      end
  """

  use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Pod]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      @before_compile Jido.Pod.BeforeCompile
    end
  end

  # … runtime helper functions (unchanged from current Jido.Pod —
  #   `get/3`, `nodes/1`, `mutate/3`, etc.)
end
```

#### `lib/jido/pod/before_compile.ex`

Update to read the resolved topology from Spark's persisted state
instead of the old `@pod_topology` module attribute:

```elixir
defmacro __before_compile__(_env) do
  quote do
    @doc "Returns the canonical topology for this pod agent."
    @spec topology() :: Jido.Pod.Topology.t()
    def topology do
      Spark.Dsl.Extension.get_persisted(__MODULE__, :resolved_topology)
    end

    @doc "Returns true for pod-wrapped agent modules."
    @spec pod?() :: true
    def pod?, do: true

    # The pod-wrapping `new/1` override (current behaviour, unchanged).
    def new(opts) do
      …
    end
  end
end
```

#### Migrate every in-tree `use Jido.Pod, …` site

Files:

- `lib/jido/pod/bus_plugin.ex` (the pod-level moduledoc example
  references `use Jido.Pod, …` — refresh).
- `test/jido/pod_test.exs` — `ExamplePod`, `EmptyPod`,
  `CustomPluginPod`, scaffolds inside tests.
- `test/jido/pod/runtime_test.exs` — multiple `use Jido.Pod, …` sites.
- `test/jido/pod/mutation_runtime_test.exs` — multiple sites.
- `test/jido/pod/mutation/planner_test.exs` — `mutation_planner_nested_pod`.
- `test/examples/runtime/pod_runtime_test.exs`,
  `nested_pod_runtime_test.exs`, `pod_scale_test.exs`,
  `nested_pod_scale_test.exs`, `mutable_pod_runtime_test.exs`,
  `partitioned_pod_runtime_test.exs`.

Each rewrites from:

```elixir
use Jido.Pod, name: "x", topology: %{…}
```

to:

```elixir
use Jido.Pod

agent do
  name "x"
end

pod do
  topology %{…}
end
```

Run the audit: `git grep -n "use Jido.Pod" lib/ test/` to find them
all.

### Legacy deletes

#### `lib/jido/dsl/agent/legacy_translator.ex`

Delete. Its only consumer was `Jido.Pod.__using__/1`; once Pod is
on its own Spark DSL, the shim has no callers.

#### `lib/jido/agent.ex`

Delete the `@agent_config_schema` Zoi schema (lines ~212–281 of
the current file) and the `config_schema/0` accessor (lines
~283–285). The agent's surface is declared by `Jido.Dsl.Agent`'s
section schema; the parallel Zoi copy is dead.

If any callers exist in tree (`grep "Jido.Agent.config_schema(" lib/`),
either delete them too or migrate to `Jido.Dsl.Agent.Info.*`
reads.

### Strip transitional task qualifiers from moduledocs

- `lib/jido/agent.ex` moduledoc: drop the `(Spark DSL — task 0034)`
  example heading qualifier; drop the "Per-extension typed sections
  … land in task 0035" paragraph. Rewrite both as stable
  description.
- `lib/jido/dsl/agent.ex` moduledoc: drop the "Per-extension typed
  sections … arrive in task 0035 once `use Jido.Slice` … themselves
  register Spark sections" note.
- `lib/jido/dsl/agent/verifiers/no_section_name_collisions.ex`
  moduledoc: drop the "For task 0034 the registered extensions
  don't yet contribute their own typed sections — they will once
  task 0035 lands" note. By this commit they do.

The verifier itself stays — it now describes how it currently
behaves, not the migration journey.

## Files to create

- `lib/jido/slice/extension.ex`
- `lib/jido/slice/extension/schema_translate.ex`
- `lib/jido/dsl/agent/transformers/discover_extensions.ex`
- `lib/jido/dsl/pod.ex`
- `lib/jido/dsl/pod/transformers/resolve_topology.ex`
- `test/jido/dsl/extension_test.exs` — covers the macro + schema-translate.
- `test/jido/dsl/extension_react_test.exs` — covers `Jido.AI.ReAct` end-to-end with a `react do … end` block. Mimic-stubs `ReqLLM.Generation.generate_text/3`.
- `test/jido/dsl/extension_compose_test.exs` — multiple contributing extensions on one host.
- `test/jido/dsl/extension_order_test.exs` — middleware-chain order preservation through contribution.
- `test/jido/dsl/extension_path_override_test.exs` — host-renamed mount path on a contributed slice (this test was outlined in [task 0038](0038-agent-dsl-optional-path-and-extension-path-override.md); the override field is implemented there, the contribution wiring lands here).

## Files to delete

- `lib/jido/dsl/agent/legacy_translator.ex`

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean (the FULL suite — no exclusions).
- `mix test --include e2e` clean (LM Studio is up locally).
- New tests cover:
  1. **Single contribution** — `extensions: [Jido.AI.ReAct]` plus a
     `react do model …; tools … end` block produces a
     `slice_instances/0` containing the ReAct slice with the typed
     config.
  2. **Multiple contributions compose** — `extensions: [ReAct,
     Memory.Slice]` plus both blocks merges cleanly.
  3. **Override form** — `extensions: [{Jido.AI.ReAct, as: :slice}]`
     mounts ReAct slice-only.
  4. **Bad config rejected at compile time** — `react do model 42 end`
     raises a `Spark.Error.DslError` citing the contributing
     extension.
  5. **Path collision** between two contributions raises
     `UniquePaths`.
  6. **Schema translate fallback** — slice with an exotic Zoi shape
     compiles cleanly with the section schema set to `[type: :any]`
     fallback; the slice author can override
     `__jido_host_contribution__/0` for richer typing.
  7. **Order preservation** — `extensions: [PluginA, MiddlewareB,
     PluginC]` produces a middleware chain in declaration order.
  8. **Path override** — `memory do path :short_term end` mounts
     `Jido.Memory.Slice` at `:short_term`; routes register against
     the new path.
  9. **Pod sectioned form** — `use Jido.Pod` + `agent do … end` +
     `pod do topology … end` produces the same runtime behaviour as
     the old keyword form.

The grep proofs:

```sh
git grep -nE "LegacyTranslator|legacy_translator|@agent_config_schema|Jido\.Agent\.config_schema\(" lib/
```

returns zero hits.

```sh
git grep -nE "task 003[0-9]" lib/
```

returns zero hits (qualifiers swept from moduledocs).

```sh
git grep -n "use Jido.Pod, " lib/ test/
```

returns zero hits — every site is on the sectioned form.

## Out of scope

- **Plugin contribution of a separate middleware section.** A `use
  Jido.Plugin` module that wants to contribute a *separate* config
  section for its middleware half (vs the one section it inherits
  via `use Jido.Slice.Extension`) — defer to a `host_middleware_section:`
  opt in a follow-up.
- **Multi-instance contributed sections.** Mounting `Memory.Slice`
  at *both* `:short_term` and `:long_term` from one host. Sections
  are singleton in Spark; the path-override field supports renaming
  to one path. Two paths needs a list-form section
  (`memories do memory :short … end`); deferred.
- **Igniter generators** that scaffold a contributing extension.
  Out of scope.
- **Cheat-sheet generation, migration guide writing, ADR status
  flip.** [Task 0042](0042-docs-and-cleanup.md).

## Risks

- **Spark dynamic-extension API.** The `Jido.Agent.__using__/1`
  override that injects shadow extensions has to compose with
  Spark's `__using__/1` correctly — `super(new_opts)` semantics
  depend on `defoverridable __using__: 1` being honoured by
  Spark's generated macro. Confirm at implementation time
  ([deps/spark/lib/spark/dsl.ex:410–415](../../deps/spark/lib/spark/dsl.ex)
  marks `__using__: 1` overridable).
- **Shadow module construction.** `Jido.Slice.Extension.__using__/1`
  needs to either generate a sibling module (e.g.
  `<SliceModule>.HostExtension`) at compile time or expose the
  contributed section through some other handshake. Module
  creation inside a `__using__` macro is awkward; alternatives
  include returning a tuple shape or letting the agent's
  `DiscoverExtensions` transformer call `__jido_host_contribution__/0`
  at parse time and wire the section into the dsl_state directly.
  Resolve at implementation; ADR 0023's "Risks" section calls this
  out as the riskiest unknown.
- **Pod state seeding.** `Jido.Pod.BeforeCompile`'s `new/1` override
  reads `topology()` and seeds the `:pod` slice. The migration moves
  topology resolution into a transformer; confirm the
  before-compile macro fires *after* the transformer persists
  `:resolved_topology`. Spark's transformer ordering is
  deterministic; this is a wiring detail.
- **Default-slices integration.** The `default_slices:` machinery
  ([Jido.Agent.DefaultSlices](../../lib/jido/agent/default_slices.ex))
  ignores extensions that came in via `default_slices:` rather than
  `extensions: [...]`. Those don't get typed-section blocks on the
  host. After [task 0039](0039-slices-must-declare-schema-and-routes.md)
  the three default slices are real slices; the user can choose
  between attaching via `default_slices:` (no typed block) or via
  `extensions:` (typed block with optional `path:` override). Both
  paths work; documented in [task 0042](0042-docs-and-cleanup.md).
