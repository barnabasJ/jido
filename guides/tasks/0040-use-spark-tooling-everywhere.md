---
name: Task 0040 — Use Spark tooling everywhere; delete hand-rolled accessors, markers, manifest projections, and discovery callbacks
descRiption: One sweeping refactor of the Jido DSL accessor / introspection / discovery surface. Each `Jido.Dsl.<Kind>` host gets a `Jido.Dsl.<Kind>.Info` module generated from `Spark.InfoGenerator`; every hand-emitted accessor (`name/0`, `path/0`, `actions/0`, `signal_routes/0`, `subscriptions/0`, `schedules/0`, `capabilities/0`, `requires/0`, `schema/0`, `config_schema/0`, `tags/0`, `category/0`, `vsn/0`, `otp_app/0`, `description/0`) deletes from the per-DSL `GenerateAccessors` transformer; callers move from `Module.foo()` to `Jido.Dsl.<Kind>.Info.foo(Module)`. The custom `__jido_slice__/0` / `__jido_plugin__/0` markers delete; `WalkExtensions` classifies modules via `Spark.Dsl.is?(mod, Jido.Slice)` / `Spark.Dsl.is?(mod, Jido.Plugin)`. The custom `__plugin_metadata__/0` / `__action_metadata__/0` / `__sensor_metadata__/0` / `__agent_metadata__/0` / `__jido_demo__/0` discovery callbacks delete; `Jido.Discovery` walks loaded apps via `Spark.Dsl.is?/2` plus the Info modules to project metadata. The `Jido.Plugin.Manifest` Zoi struct + per-DSL `manifest/0` and `plugin_spec/1` projections delete; downstream code reads fields directly through the Info modules.
---

# Task 0040 — Use Spark tooling everywhere

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 (Spark introspection is the canonical surface).
- Depends on: [task 0036](0036-port-action-and-sensor-to-spark.md), [task 0037](0037-slice-dsl-cleanup.md), [task 0038](0038-agent-dsl-optional-path-and-extension-path-override.md), [task 0039](0039-slices-must-declare-schema-and-routes.md).
- Blocks: [task 0041](0041-extensions-contribute-dsl-sections.md).
- Leaves tree: **green**.

## Context

The Spark migration (tasks 0033–0036) ported every `use Jido.X` site
to a Spark DSL. What it didn't do — because the migration was
mechanical — is replace the hand-rolled introspection surface that
predates Spark with the equivalent Spark tooling. The current state:

1. **Hand-rolled accessors.** `lib/jido/dsl/slice/transformers/generate_accessors.ex`
   emits ~200 lines of `quote def …` that produce
   `MyModule.name/0`, `MyModule.path/0`, `MyModule.actions/0`,
   `MyModule.signal_routes/0`, `MyModule.subscriptions/0`,
   `MyModule.schedules/0`, `MyModule.capabilities/0`,
   `MyModule.requires/0`, `MyModule.schema/0`,
   `MyModule.config_schema/0`, `MyModule.tags/0`,
   `MyModule.category/0`, `MyModule.vsn/0`, `MyModule.otp_app/0`,
   `MyModule.description/0`. Every per-DSL host has a similar
   generator. Spark ships [`Spark.InfoGenerator`](../../deps/spark/lib/spark/info_generator.ex)
   that produces these exact accessors automatically from a
   section's schema.
2. **Custom kind markers.** [`Jido.Slice.handle_opts/1`](../../lib/jido/slice.ex#L75-L83)
   emits `def __jido_slice__, do: true`; [`Jido.Plugin.handle_opts/1`](../../lib/jido/plugin.ex#L17-L29)
   emits both `__jido_slice__/0` and `__jido_plugin__/0`. These
   are read by [`WalkExtensions.classify/1`](../../lib/jido/dsl/agent/transformers/walk_extensions.ex#L93-L117)
   to dispatch a module into the slice / plugin / middleware bucket.
   Spark already persists `@spark_is parent` ([deps/spark/lib/spark/dsl.ex:370–376](../../deps/spark/lib/spark/dsl.ex))
   on every host module — `Spark.Dsl.is?(mod, Jido.Slice)` returns
   `true` iff the module did `use Jido.Slice`. Native, no custom
   marker needed.
3. **Hand-rolled discovery callbacks.** Each per-DSL accessor
   generator emits one or more of `__plugin_metadata__/0`,
   `__action_metadata__/0`, `__sensor_metadata__/0`,
   `__agent_metadata__/0`, `__jido_demo__/0`. [`Jido.Discovery.discover_components/1`](../../lib/jido/discovery.ex#L234-L239)
   walks `Application.loaded_applications()` and filters modules by
   `function_exported?(module, callback, 0)`. The same walk works
   off `Spark.Dsl.is?/2` — the modules of interest are exactly those
   that did `use Jido.<Kind>`.
4. **Manifest / plugin_spec projections.** [`Jido.Plugin.Manifest`](../../lib/jido/plugin/manifest.ex)
   is a Zoi struct that bundles `name`, `path`, `description`,
   `category`, `tags`, `vsn`, `actions`, `signal_routes`, `schema`,
   `config_schema`, `singleton`, `capabilities`. The slice DSL emits
   `manifest/0` returning this struct + a separate `plugin_spec/1`
   variant. Both are projections of the slice's `dsl_state`. Spark's
   Info modules + direct `dsl_state` access give downstream code
   field-level reads without an intermediate struct.
5. **Custom `defoverridable` block.** The slice's accessor generator
   emits a `defoverridable name: 0, path: 0, …` block over 17
   accessor names so an author can replace any one with a custom
   implementation. With `Spark.InfoGenerator` the accessors live on
   a separate Info module — overrides happen by overriding the Info
   module's function in the host module if needed. The
   `defoverridable` block deletes; the few in-tree overrides
   migrate to the Info-module pattern (likely zero in tree).

After this commit:

- Every per-DSL host has a `Jido.Dsl.<Kind>.Info` module
  (`Jido.Dsl.Slice.Info`, `Jido.Dsl.Plugin.Info`,
  `Jido.Dsl.Middleware.Info`, `Jido.Dsl.Action.Info`,
  `Jido.Dsl.Sensor.Info`, `Jido.Dsl.Agent.Info`,
  `Jido.Dsl.Instance.Info`).
- The hand-rolled accessor emit blocks in every per-DSL
  `GenerateAccessors` transformer delete (or shrink to
  framework-internal accessors only — e.g. the slice's `actions/0`
  derived from routes, which is a transformation, not a passthrough).
- `Jido.Discovery` walks Spark hosts via `Spark.Dsl.is?/2` and
  reads metadata via the Info modules.
- `Jido.Plugin.Manifest` deletes; `Jido.Plugin.Instance` /
  `Jido.Slice.Instance` read fields directly from the module via
  the Info module.
- `__jido_slice__/0` / `__jido_plugin__/0` / `__plugin_metadata__/0`
  / `__action_metadata__/0` / `__sensor_metadata__/0` /
  `__agent_metadata__/0` / `__jido_demo__/0` are gone from `lib/`.

## Goal

After this commit a slice declaration looks unchanged from the
author's perspective:

```elixir
defmodule MyApp.ChatSlice do
  use Jido.Slice

  slice do
    name "chat"
    path :chat
    schema MyApp.Chat.schema()
  end

  signal_routes do
    route "chat.send", MyApp.Actions.Send
  end
end
```

…but the introspection surface is Spark-native:

```elixir
# Before
MyApp.ChatSlice.name()        #=> "chat"
MyApp.ChatSlice.path()        #=> :chat
MyApp.ChatSlice.signal_routes()
MyApp.ChatSlice.manifest()    #=> %Jido.Plugin.Manifest{...}

# After
Jido.Dsl.Slice.Info.name(MyApp.ChatSlice)            #=> "chat"
Jido.Dsl.Slice.Info.path(MyApp.ChatSlice)            #=> :chat
Jido.Dsl.Slice.Info.signal_routes(MyApp.ChatSlice)   #=> [%Route{...}]
# manifest/0 is gone — read individual fields via Info.
```

The host-module functions (`MyApp.ChatSlice.name/0`, `.path/0`)
delete. Every callsite in `lib/` and `test/` migrates to the Info
shape. This is a hard cut — no `defdelegate` shim, no transitional
`def name, do: Info.name(__MODULE__)` adapter (NO LEGACY ADAPTERS,
[guides/tasks/README.md](README.md)).

`WalkExtensions` switches its kind-classification:

```elixir
# Before
plugin? = function_exported?(module, :__jido_plugin__, 0)
slice?  = function_exported?(module, :__jido_slice__, 0)

# After
plugin? = Spark.Dsl.is?(module, Jido.Plugin)
slice?  = Spark.Dsl.is?(module, Jido.Slice)
```

`Jido.Discovery` switches its catalog walk:

```elixir
# Before
Application.loaded_applications()
|> Enum.flat_map(&modules_for/1)
|> Enum.filter(&function_exported?(&1, :__plugin_metadata__, 0))
|> Enum.map(&build_metadata(&1, :__plugin_metadata__))

# After
Application.loaded_applications()
|> Enum.flat_map(&modules_for/1)
|> Enum.filter(&Code.ensure_loaded?/1)
|> Enum.filter(&Spark.Dsl.is?(&1, Jido.Plugin))
|> Enum.map(&plugin_catalog_entry/1)

defp plugin_catalog_entry(module) do
  %{
    module: module,
    name: Jido.Dsl.Slice.Info.name(module),    # Plugin uses Slice DSL + plugin marker
    description: Jido.Dsl.Slice.Info.description(module),
    category: Jido.Dsl.Slice.Info.category(module),
    tags: Jido.Dsl.Slice.Info.tags(module),
    slug: slug_for(module)
  }
end
```

## Files to modify

### `lib/jido/dsl/slice/info.ex` (new)

```elixir
defmodule Jido.Dsl.Slice.Info do
  @moduledoc """
  Introspection surface for `use Jido.Slice` modules. Each accessor
  takes the slice module and reads a field from its Spark
  `dsl_state`.
  """

  use Spark.InfoGenerator,
    extension: Jido.Dsl.Slice,
    sections: [:slice, :signal_routes, :subscriptions, :schedules, :capabilities, :requires]
end
```

`Spark.InfoGenerator` emits one accessor per option in each
section's schema. For `slice do … end` that produces
`Jido.Dsl.Slice.Info.name/1`, `.path/1`, `.description/1`,
`.category/1`, `.vsn/1`, `.otp_app/1`, `.schema/1`,
`.config_schema/1`, `.tags/1`. For entity-list sections like
`signal_routes` it produces `.signal_routes/1` returning the entity
list. Same for the other sections.

### `lib/jido/dsl/plugin/info.ex` (new)

```elixir
defmodule Jido.Dsl.Plugin.Info do
  use Spark.InfoGenerator,
    extension: Jido.Dsl.Plugin,
    sections: [:slice, :signal_routes, :subscriptions, :schedules, :capabilities, :requires]
end
```

(Plugin DSL re-exports the slice sections — see `Jido.Dsl.Plugin`'s
`add_extensions: [Jido.Dsl.Slice]` if applicable, or its
`sections: [...]` direct list. Confirm at implementation time.)

### `lib/jido/dsl/middleware/info.ex` (new)

```elixir
defmodule Jido.Dsl.Middleware.Info do
  use Spark.InfoGenerator,
    extension: Jido.Dsl.Middleware,
    sections: [:middleware]
end
```

### `lib/jido/dsl/action/info.ex` (new)

```elixir
defmodule Jido.Dsl.Action.Info do
  use Spark.InfoGenerator,
    extension: Jido.Dsl.Action,
    sections: [:action]
end
```

### `lib/jido/dsl/sensor/info.ex` (new)

```elixir
defmodule Jido.Dsl.Sensor.Info do
  use Spark.InfoGenerator,
    extension: Jido.Dsl.Sensor,
    sections: [:sensor]
end
```

### `lib/jido/dsl/agent/info.ex` (new)

```elixir
defmodule Jido.Dsl.Agent.Info do
  use Spark.InfoGenerator,
    extension: Jido.Dsl.Agent,
    sections: [:agent, :signal_routes, :schedules]
end
```

### `lib/jido/dsl/instance/info.ex` (new)

```elixir
defmodule Jido.Dsl.Instance.Info do
  use Spark.InfoGenerator,
    extension: Jido.Dsl.Instance,
    sections: [...]   # whatever sections Jido.Dsl.Instance defines
end
```

### `lib/jido/dsl/slice/transformers/generate_accessors.ex`

Strip the hand-rolled accessor block. What remains in this
transformer (if anything):

- Anything that's a *transformation* of a section, not a passthrough.
  After [task 0037](0037-slice-dsl-cleanup.md), `actions/0` is
  derived from `signal_routes/0` (`Enum.uniq` of route action
  targets). That derivation is implemented as a Spark transformer
  that persists `:actions` into `dsl_state`, which `Info.actions/1`
  then reads via `Spark.Dsl.Extension.get_persisted/3`.
- The `__jido_slice__/0` marker emit deletes.
- The `manifest/0` and `plugin_spec/1` emits delete.
- The `__plugin_metadata__/0` emit deletes.
- The `defoverridable` block deletes.

If the surviving content is small, rename the transformer to
something narrower (`Jido.Dsl.Slice.Transformers.DeriveActions`) and
delete `GenerateAccessors` entirely. Other per-DSL accessor
generators get the same treatment.

### `lib/jido/dsl/agent/transformers/generate_accessors.ex`

Same treatment for the agent's accessor generator. The agent's
hand-rolled accessor block deletes.

### `lib/jido/dsl/agent/transformers/walk_extensions.ex`

Switch the kind-classification:

```elixir
defp classify(entry) do
  {module, opts, as_override} = normalize_entry(entry)
  ensure_module_loaded!(module)

  plugin?     = Spark.Dsl.is?(module, Jido.Plugin)
  slice?      = Spark.Dsl.is?(module, Jido.Slice)
  middleware? = behaves_as_middleware?(module)

  kind = pick_kind(module, plugin?, slice?, middleware?, as_override)
  …
end
```

`behaves_as_middleware?/1` keeps reading the `:behaviour` attribute
because middleware is a behaviour, not a Spark host (it has its own
`use Jido.Middleware` but that uses Spark.Dsl too — confirm at
implementation: if `Spark.Dsl.is?(mod, Jido.Middleware)` is the
right check, use it; if middleware modules are *also* Spark hosts
plus the behaviour, use both checks combined).

### `lib/jido/slice.ex`

The `handle_opts/1` block currently emits `def __jido_slice__, do:
true`. Drop it entirely:

```elixir
@impl Spark.Dsl
def handle_opts(_opts) do
  quote do: nil
end
```

…or remove the whole `handle_opts/1` if it's the only thing it did.
The slice module is now identified solely by `Spark.Dsl.is?(mod,
Jido.Slice)`.

### `lib/jido/plugin.ex`

Same: drop the `__jido_slice__/0` and `__jido_plugin__/0` emits.
The plugin module is identified by `Spark.Dsl.is?(mod, Jido.Plugin)`
(or by its parent host's identity, depending on how Spark's `@spark_is`
chains for nested DSL inheritance — confirm at implementation).

### `lib/jido/discovery.ex`

Replace the `discover_components/1` machinery to walk Spark hosts:

```elixir
defp build_catalog do
  %{
    last_updated: DateTime.utc_now(),
    components: %{
      actions: discover(Jido.Action, &action_metadata/1),
      sensors: discover(Jido.Sensor, &sensor_metadata/1),
      agents: discover(Jido.Agent, &agent_metadata/1),
      plugins: discover(Jido.Plugin, &plugin_metadata/1),
      demos: discover_demos()   # demos may need a different signal
    }
  }
end

defp discover(parent_dsl, metadata_fn) do
  Application.loaded_applications()
  |> Enum.flat_map(&modules_for/1)
  |> Enum.filter(&Code.ensure_loaded?/1)
  |> Enum.filter(&Spark.Dsl.is?(&1, parent_dsl))
  |> Enum.map(&metadata_fn.(&1))
end

defp action_metadata(mod) do
  %{
    module: mod,
    name: Jido.Dsl.Action.Info.name(mod),
    description: Jido.Dsl.Action.Info.description(mod),
    category: Jido.Dsl.Action.Info.category(mod),
    tags: Jido.Dsl.Action.Info.tags(mod),
    slug: slug_for(mod)
  }
end
# … same shape for plugin_metadata / agent_metadata / sensor_metadata
```

### `lib/jido/plugin/manifest.ex`

Delete the entire file. Anything that constructs a `%Jido.Plugin.Manifest{}`
now reads individual fields from `Jido.Dsl.Slice.Info` /
`Jido.Dsl.Plugin.Info`.

### `lib/jido/plugin/instance.ex`

Replace `manifest = module.manifest()` with direct Info-module
reads:

```elixir
def new(plugin_declaration) do
  {module, as_opt, overrides} = normalize_declaration(plugin_declaration)

  base_path = Jido.Dsl.Plugin.Info.path(module)
  base_name = Jido.Dsl.Plugin.Info.name(module)
  resolved_config = Config.resolve_config!(module, overrides)

  %__MODULE__{
    module: module,
    as: as_opt,
    config: resolved_config,
    path: derive_path(base_path, as_opt),
    route_prefix: derive_route_prefix(base_name, as_opt)
    # `manifest` field on the struct deletes; downstream reads via Info
  }
end
```

### `lib/jido/slice/instance.ex`

Same: `slice_instance.manifest` field deletes. Callers switch to
`Jido.Dsl.Slice.Info.<accessor>(slice_instance.module)`.

### Callers across `lib/` and `test/`

Every callsite that does `Module.name()`, `Module.path()`,
`Module.actions()`, etc. on a slice/plugin/action/sensor/agent
module migrates to `Jido.Dsl.<Kind>.Info.<accessor>(Module)`. Run:

```sh
git grep -nE 'Module\.(name|path|description|category|tags|vsn|otp_app|schema|config_schema|actions|signal_routes|subscriptions|schedules|capabilities|requires|manifest|plugin_spec)\(\)'
```

…against `lib/` and `test/` to find them all. Estimate is in the
hundreds of callsites; this is the bulk of the diff.

For test fixtures that define a slice module and call its accessor
in the same file, the test code rewrites to the Info form too.
Don't ship a `defdelegate name, to: Info` adapter on the host
module — that's a legacy shim.

### Tests

Existing per-DSL accessor tests rewrite to assert the Info form:

```elixir
# Before
test "name accessor returns slice name" do
  assert MySlice.name() == "my_slice"
end

# After
test "Info.name returns slice name" do
  assert Jido.Dsl.Slice.Info.name(MySlice) == "my_slice"
end
```

Test churn is large but mechanical. Discovery tests rewrite to
exercise the Spark-walk path:

```elixir
test "Discovery finds plugins" do
  Jido.Discovery.refresh()
  modules = Jido.Discovery.list_plugins() |> Enum.map(& &1.module)
  assert Jido.Pod.Plugin in modules
end
```

(That assertion already works; the implementation change is
underneath.)

### `lib/jido/igniter/templates.ex`

The Igniter template scaffolding emits `plugin_spec/1` and
`__plugin_metadata__/0` references in generated test files. Update
the templates to emit Info-module assertions.

## Files to delete

- `lib/jido/plugin/manifest.ex` — projection struct, no longer
  needed.
- Any per-DSL accessor generator file that becomes empty after the
  hand-rolled accessor block deletes.

## Acceptance

- `mix compile --warnings-as-errors` clean for `lib/`.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean (the FULL suite — no exclusions).
- `mix test --include e2e` clean.
- `mix docs` runs clean.

The grep proofs:

```sh
git grep -nE '__jido_slice__|__jido_plugin__|__plugin_metadata__|__action_metadata__|__sensor_metadata__|__agent_metadata__|__jido_demo__' lib/
```

returns zero hits in `lib/` (test fixtures may keep them temporarily;
sweep in the same commit).

```sh
git grep -nE '\.manifest\(\)|\.plugin_spec\(' lib/ test/
```

returns zero hits.

```sh
git grep -nE 'def (name|path|description|category|tags|vsn|otp_app|schema|config_schema|actions|signal_routes|subscriptions|schedules|capabilities|requires)\(?\)?, do' lib/jido/dsl/
```

returns only the Info-module-generated accessors (i.e. zero
hand-rolled emits in transformer files).

The behavioural surface for the framework's runtime is unchanged —
agent dispatch, plugin instance construction, signal routing, slice
mounting — all keep working because the underlying `dsl_state` is
the same. What changes is *how the framework reads its own
metadata*.

## Out of scope

- **Schema language consolidation.** [ADR
  0024](../adr/0024-schema-language-consolidation.md) captures the
  Zoi / NimbleOptions / Spark.Options situation; that decision is
  open. This task does not migrate any action's schema shape.
- **The contribution mechanism.** [Task
  0041](0041-extensions-contribute-dsl-sections.md) builds
  `Jido.Slice.Extension` on top of the cleaner accessor surface this
  task ships. 0041 reads contributed-section config via
  `Jido.Dsl.<Kind>.Info.*` calls produced here.
- **Pod migration to a Spark host.** Also in [task
  0041](0041-extensions-contribute-dsl-sections.md).

## Risks

- **Accessor naming collisions on the Info module.**
  `Spark.InfoGenerator` produces `name/1` from the `:name` schema
  option. If two sections both have a `:name` option (e.g.
  `slice.name` and `signal_routes.route.name`), the generator
  needs explicit pathing. Read [`Spark.InfoGenerator` source](../../deps/spark/lib/spark/info_generator.ex)
  before assuming the naïve form works for nested entities.
- **Override pattern lost.** The `defoverridable` block let an
  author replace `name/0` with a custom implementation directly on
  the module. With Info modules, the equivalent is to override the
  Info-module's function in the host module via
  `defoverridable Info.name: 1` — which doesn't really work because
  Info isn't generated *into* the host. If a slice currently
  overrides one of its accessors in tree, its migration path needs
  thinking through. Audit `git grep -nE 'def name\b|def path\b'
  lib/` before deletion to see if any slice module is doing this.
  (Likely zero hits in tree, but check.)
- **Discovery for `__jido_demo__/0`.** Demos aren't a Spark DSL —
  the marker is a one-off function. Either keep the marker for
  demos (with a moduledoc note that demos are special) or migrate
  demos to a `use Jido.Demo` Spark DSL of their own. Smaller scope
  to keep the marker; larger scope to make demos consistent. Pick
  at implementation time.
- **`Jido.Plugin.Manifest` deletion ripple.** Any external code that
  constructs or matches on `%Jido.Plugin.Manifest{}` breaks. The
  framework is pre-1.0; per the NO LEGACY ADAPTERS rule, no
  deprecation. Document the migration in [task
  0042](0042-docs-and-cleanup.md)'s migration guide.
- **Spark.InfoGenerator option schemas.** If a section's schema
  has `type: :any` (e.g. `slice.schema`), the Info-module accessor
  returns the term as-is — no validation re-run. That's the same
  behaviour as the hand-rolled accessor today. Confirm at
  implementation.
- **DSL inheritance / re-exports.** If `Jido.Dsl.Plugin` re-exports
  `Jido.Dsl.Slice`'s sections, a single `Plugin.Info` module may
  not surface those re-exported sections; might need `Plugin.Info`
  to delegate to `Slice.Info` for slice-shared accessors. Read the
  relevant Spark DSL code at implementation time and pick the
  cleanest pattern.
