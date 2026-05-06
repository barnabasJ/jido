# 0023. Spark DSL for `use` sites; slices / middleware / plugins are registerable extensions

- Status: Accepted; the Plugin (`use Jido.Plugin`) extension shape referenced
  here was retired in [0028](0028-deprecate-jido-plugin.md). Slice / Middleware
  shapes stand.
- Implementation: Complete
- Date: 2026-04-28
- Related ADRs: [0014](0014-slice-middleware-plugin.md) (the Slice / Middleware
  / Plugin split), [0022](0022-llm-agents-inlined-jido-ai-namespace.md) (LLM
  agent surface that benefits most from per-extension DSL sections),
  [0019](0019-actions-mutate-state-directives-do-side-effects.md),
  [0021](0021-no-full-state-no-polling.md).
- Implementation tasks:
  [0033](../tasks/0033-spark-dep-and-jido-dsl-scaffold.md),
  [0034](../tasks/0034-port-jido-agent-to-spark.md),
  [0035](../tasks/0035-port-slice-plugin-middleware-to-spark.md),
  [0036](../tasks/0036-port-action-and-sensor-to-spark.md),
  [0037](../tasks/0037-slice-dsl-cleanup.md),
  [0038](../tasks/0038-agent-dsl-optional-path-and-extension-path-override.md),
  [0039](../tasks/0039-slices-must-declare-schema-and-routes.md),
  [0040](../tasks/0040-use-spark-tooling-everywhere.md),
  [0041](../tasks/0041-extensions-contribute-dsl-sections.md),
  [0042](../tasks/0042-docs-and-cleanup.md).
- Related ADRs: [0024](0024-schema-language-consolidation.md) (open — runtime
  schema language consolidation; orthogonal to the DSL migration but shares the
  schema-validation territory).

## Context

Every `use Jido.X` site in the framework currently rolls its own compile-time
machinery. `lib/jido/agent.ex` is the worst offender: a 345-line `__using__`
plus eleven `__quoted_*__/0` helpers that stitch together a Zoi config schema,
multiple compile-time aggregators, and defoverridable accessors.
`lib/jido/slice.ex`, `lib/jido/plugin.ex`, `lib/jido/middleware.ex`,
`lib/jido/action.ex`, `lib/jido/sensor.ex`, `lib/jido/pod.ex`, and `lib/jido.ex`
each repeat the same pattern in miniature: a private Zoi `@*_config_schema`, a
`defmacro __using__` that parses opts, and a hand-written set of accessor
functions that read `@validated_opts`.

This pays in three places:

1. **Authoring.** Adding a new compile-time option to `Jido.Agent` means: edit
   the schema, edit `__quoted_compile_options__/1`, edit the relevant accessor
   block, edit one or more validators, and probably touch
   `__quoted_compile_aggregates__/0` if it interacts with plugins or slices.
   There is no single shape that says "here is the agent surface."
2. **Tooling.** Editor support is whatever the keyword-list parser gives us — no
   autocomplete inside `use Jido.Agent, …`, no formatter awareness, no
   per-option doc generation, no introspection beyond reading `@validated_opts`.
   The framework is shipped with `mix.exs` references to documentation but not
   to a structured DSL spec.
3. **Composition.** [ADR 0014](0014-slice-middleware-plugin.md) establishes that
   slices, middleware, and plugins are the composition vocabulary;
   [ADR 0022 §6](0022-llm-agents-inlined-jido-ai-namespace.md) pushes config
   into the slice (`slices: [{Jido.AI.ReAct, model: "…", tools: […]}]`). The
   slice author cannot contribute to the agent's DSL — they hand keyword tuples
   through a generic `slices:` slot, the agent module receives them opaquely,
   and the surface for an AI-shaped agent is a config blob inside a list rather
   than a first-class section. Compare Ash, where
   `use Ash.Resource, extensions: [AshGraphql.Resource]` lets the resource
   module declare a `graphql do … end` block whose entities are validated,
   documented, and introspected by Spark. We owe our extension authors the same
   surface.

Spark — the DSL toolkit Ash is built on — already solves all three. It is a
single dep (`{:spark, "~> 2.2"}`), it is well-tested across years of Ash usage,
and it gives us:

- Declarative `Spark.Dsl.Section` / `Spark.Dsl.Entity` definitions in place of
  hand-rolled `__quoted_*__` blocks.
- Compile-time `transformers/0` and `verifiers/0` that replace our ad-hoc
  `__quoted_compile_aggregates__` raises.
- `Spark.Dsl.Extension` so that _any_ module — a slice, a plugin, a middleware,
  an out-of-tree library — can contribute new sections and entities to a host
  module.
- `Spark.Igniter` integration we already pull in for code generation.
- A `mix spark.formatter` task and an `mix spark.cheat_sheets` task that produce
  per-DSL reference docs for free.

The cost is one new dep, a finite migration of every `use` site, and a one-time
stylistic break for users who learned the keyword-list shape.

## Decision

We will rewrite every `use Jido.X` site as a Spark DSL, we will make slices,
middleware, and plugins first-class **DSL extensions** that each contribute
their own typed block to a host agent, and we will derive ordering from the
`extensions: [...]` keyword list passed to `use Jido.Agent`.

### 1. `Jido.Dsl.*` is the home for DSL definitions

Each public surface gets a corresponding Spark DSL module under `lib/jido/dsl/`:

| Surface               | DSL module            |
| --------------------- | --------------------- |
| `use Jido.Agent`      | `Jido.Dsl.Agent`      |
| `use Jido.Slice`      | `Jido.Dsl.Slice`      |
| `use Jido.Plugin`     | `Jido.Dsl.Plugin`     |
| `use Jido.Middleware` | `Jido.Dsl.Middleware` |
| `use Jido.Action`     | `Jido.Dsl.Action`     |
| `use Jido.Sensor`     | `Jido.Dsl.Sensor`     |
| `use Jido`            | `Jido.Dsl.Instance`   |

`Jido.Agent` becomes a thin shim:

```elixir
defmodule Jido.Agent do
  use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Agent]]
end
```

The behaviour callbacks (`signal_routes/0`, `checkpoint/2`, `restore/2`) and the
public functional API (`new/1`, `set/2`, `validate/2`, `cmd/2`, `schema/0`,
etc.) live alongside. The `__quoted_*__/0` zoo deletes; the per-section
transformers and runtime accessors generated by Spark replace them.

### 2. The agent DSL is sectioned

```elixir
defmodule MyAgent do
  use Jido.Agent,
    extensions: [
      Jido.Memory.Slice,
      Jido.AI.ReAct,
      Jido.Middleware.Retry,
      MyApp.AuditPlugin
    ]

  agent do
    name "support"
    description "Support agent"
    path :domain
    schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
  end

  signal_routes do
    route "user.created", HandleUserCreated, priority: 5
    route "payment.*", LargePayment, match: &(&1.data.amount > 100)
  end

  schedules do
    schedule "*/5 * * * *", "tick.heartbeat"
  end

  # typed block contributed by Jido.Memory.Slice
  memory do
    backend MyApp.MemoryBackend
    namespace :support
  end

  # typed block contributed by Jido.AI.ReAct
  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [MyApp.Actions.LookupOrder, MyApp.Actions.RefundOrder]
    system_prompt "You are a support agent."
    max_iterations 5
  end

  # typed block contributed by Jido.Middleware.Retry
  retry do
    max_retries 3
    backoff_ms 100
  end

  # typed block contributed by MyApp.AuditPlugin
  audit do
    sink MyApp.AuditLog
    redact [:user_email]
  end
end
```

The `agent do … end`, `signal_routes do … end`, and `schedules do … end` blocks
are sections owned by `Jido.Dsl.Agent` (the host's own DSL). The
`memory do … end`, `react do … end`, `retry do … end`, and `audit do … end`
blocks are sections owned by **the contributing extension**: each module listed
in `extensions: [...]` is itself a `Spark.Dsl.Extension` and contributes one
section to the host.

There is **no host-level `extensions do … end` block**. The `extensions: [...]`
keyword on `use Jido.Agent` is the registration list (Spark-native —
`use Spark.Dsl, default_extensions: [extensions: [...]]`); each module's own DSL
block is where the user puts its config.

### 3. Kind is inferred; chain order is the `extensions: [...]` keyword

Two questions the keyword-form `plugins:` / `middleware:` / `slices:` shape left
implicit:

1. **What kind of contribution is this — slice, plugin, or middleware?** The
   contributing module already knows. We read it off the markers:
   `__jido_slice__/0`, `__jido_plugin__/0`, and the `Jido.Middleware` behaviour.
   No `as:` keyword anywhere normally.
2. **What order do plugins and middleware run in the chain?** The
   `extensions: [...]` keyword list IS the order. It's already a single ordered
   list, and reading it tells the user the chain shape at a glance.

Three rules:

- **Kind is inferred from the module.** A module with the `__jido_plugin__/0`
  marker is a plugin (slice half + middleware half); a module with
  `__jido_slice__/0` only is a slice; a module with `Jido.Middleware` behaviour
  only is a middleware. Modules matching none raise `CompileError` at the host's
  compile time pointing at the offending entry.
- **`extensions: [...]` declaration order is the chain order.** For plugins
  (middleware half) and middleware entries the keyword-list order maps 1:1 to
  chain order: the first listed wraps the second, the second wraps the third,
  the last wraps core. Slices are unordered (mounted at their `path()`).
- **Override via keyword tuple — rare escape hatch.** When a user needs to
  attach a `use Jido.Plugin` module slice-only (skipping the middleware half),
  the keyword form supports it: `extensions: [{Jido.AI.ReAct, as: :slice}]`. The
  same form rejects bad overrides (`{BareSlice, as: :plugin}` with no middleware
  half raises). 99% of agents never need this; document and move on.

The convenience accessors stay: `MyAgent.plugins/0` returns plugin entries;
`.middleware/0` returns middleware entries (in chain order); `.slices/0` returns
slice entries. They're filter projections over the registered extensions.

Section-name collisions across extensions (two libraries both contributing a
`:react` block) are an authoring error — the host can't disambiguate. A verifier
on `Jido.Dsl.Agent` raises `CompileError` listing the colliding modules; the fix
is for one library to rename its section.

### 4. Slices, middleware, and plugins are extensions

Every concrete `use Jido.Slice` / `use Jido.Plugin` / `use Jido.Middleware`
module exposes itself as a Spark extension by defining a `Spark.Dsl.Extension`:

```elixir
defmodule Jido.AI.ReAct do
  use Jido.Slice,
    name: "react",
    path: :ai,
    actions: [Jido.AI.ReAct.Action.Step]

  use Spark.Dsl.Extension,
    sections: [@react_section]

  @react_section %Spark.Dsl.Section{
    name: :react,
    schema: [
      model: [type: :any, required: true,
              doc: "ReqLLM model spec; string, struct, or {provider, opts}"],
      tools: [type: {:list, :atom}, default: []],
      system_prompt: [type: :string, default: ""],
      max_iterations: [type: :pos_integer, default: 5],
      llm_opts: [type: :keyword_list, default: []]
    ]
  }
end
```

When a host agent declares `extensions: [Jido.AI.ReAct]`:

- Spark adds the `react do … end` section to the host's DSL.
- The user fills in `model`, `tools`, etc. with autocomplete and per-option
  docs, validated against the section's schema at compile time.
- A transformer on `Jido.Dsl.Agent` walks each registered extension, reads its
  typed section out of the host's DSL state, classifies the module by marker
  (`__jido_slice__`, `__jido_plugin__`, `Jido.Middleware`), and slots the entry
  into the host's internal slice / plugin / middleware lists. Order in those
  lists is preserved from the `extensions: [...]` keyword.
- The slice's `path/0`, `schema/0`, `actions/0`, and `signal_routes/0` register
  through the same machinery introduced by
  [task 0032](../tasks/0032-framework-slices-attachment-option.md); this ADR
  does not re-litigate the slice-attachment story, only the DSL surface for it.

The same pattern applies to plugins (`use Jido.Plugin` modules contribute one
section covering both their slice half and middleware-specific options; the
marker classifies them as plugin so both halves register) and to bare middleware
modules (`use Jido.Middleware` modules contribute a section if they have
configurable options; bare middleware with no config can be listed in
`extensions: [...]` and skip the typed block entirely — the section is optional
when the schema has no required fields).

### 5. Migration is a hard cut

Every in-tree `use Jido.X` callsite migrates in lockstep with the DSL
definitions. There is no `default_options` shim, no "if you pass a keyword list
it still works" branch, no `@deprecated` warning that keeps the old keyword
shape alive. The framework is pre-1.0
([ADR 0014](0014-slice-middleware-plugin.md),
[tasks/README.md](../tasks/README.md) NO LEGACY ADAPTERS guidance), and Spark
gives us a clean break we should take in one swing.

The implementation lands across ten commits
([tasks 0033–0042](../tasks/README.md)), with a deliberately red middle: tasks
0034–0035 each leave the tree partially migrated; tasks 0036+ leave it green.
Task 0042 (docs, cheat sheets, status flip) is the terminal commit.

### 6. Public API stability

Calling `MyAgent.cmd/2`, `MyAgent.new/1`, `MyAgent.signal_routes/0`,
`MyAgent.actions/0`, `MyAgent.plugin_instances/0`, etc. is unchanged. The DSL is
**how the user writes the module**; the **runtime API the agent exposes** keeps
its current shape. Spark generates the same accessor functions we hand-write
today, and our transformers populate the same module attributes
(`@plugin_instances`, `@slice_instances`, `@expanded_signal_routes`, …) that
downstream code reads from.

`Jido.AI.ask/3` / `ask_sync/3`
([ADR 0022](0022-llm-agents-inlined-jido-ai-namespace.md)) do not change shape.
Tests that assert against `MyAgent.plugins/0` or `MyAgent.signal_routes/0` keep
passing.

## Consequences

- **One declarative shape per surface.** A reader looking at
  `lib/jido/dsl/agent.ex` sees the entire agent surface in one schema-driven
  file. Adding a new compile-time option means adding one entity / option to one
  section, not editing six files.
- **First-class extension story.** Slice and plugin authors no longer hand the
  host agent an opaque keyword tuple. They declare a Spark section; the host's
  DSL document picks it up; the user gets autocomplete, formatter awareness, and
  structured docs. ADR 0014's "slices/middleware/plugins are the composition
  vocabulary" lands with tooling worthy of the design.
- **Ordering is explicit.** ADR 0014 left the chain order as the implicit
  "middleware list, then plugin middleware halves in declaration order"; users
  could not interleave a middleware between two plugins without reordering both
  buckets. The `extensions: [...]` keyword on `use Jido.Agent` is now the single
  ordered registration list — what the user writes top-to-bottom is what the
  chain wraps inside-out. `MyAgent.plugins/0` / `.middleware/0` / `.slices/0`
  remain available as filter projections classified by the modules' markers.
- **One block per extension.** Each registered module owns one typed DSL block
  (`memory do`, `react do`, `retry do`, …). The block name is the extension's
  choice, validated against the extension's schema, scoped to that extension's
  docs. Authors don't see a unified `extensions do … end` blob with per-entry
  config keywords — they see one block per concept they added to the agent.
- **Free docs and tooling.** `mix spark.cheat_sheets` produces a reference page
  for every DSL we ship; `mix spark.formatter` keeps user code formatted;
  ElixirLS picks up DSL options automatically. We retire the hand-maintained
  option lists in `guides/agents.md` and `guides/slices.md` in favour of
  generated reference plus conceptual prose.
- **One new dep.** `{:spark, "~> 2.2"}` becomes a runtime dep of jido. Spark is
  small, has no transitive deps beyond `:nimble_options` (which we already use
  indirectly), and is the foundation for Ash — it is unlikely to disappear.
- **Hard break for existing user code.** Every agent module in this repo and in
  user repos rewrites its `use Jido.Agent, …` call to the sectioned DSL. The
  migration is mechanical (regex-driven for the bulk of cases) but it is
  invasive in line count. Per the NO LEGACY ADAPTERS rule, we do not ship a
  keyword-list shim. We do ship a section in `guides/migration.md` walking
  through one or two real-world examples.
- **Four schema languages coexist at different layers.** Compile-time DSL
  options validate through **Spark.Options** — a vendored fork of NimbleOptions
  ([deps/spark/lib/spark/options/options.ex:113–132](../../deps/spark/lib/spark/options/options.ex))
  with extra types and a compile-time validator. Spark.Options is _not_ the same
  as the standalone `:nimble_options` dep. At runtime, action / slice / agent
  state schemas use **Zoi** (the framework's struct generator
  - Zod-shape validator); action input schemas can also be plain
    **NimbleOptions** keyword lists; and `Jido.Action.Schema` accepts a third
    shape — **JSON Schema maps** — as a passthrough format used by LLM-tool
    exports (`schema_type/1` returns `:json_schema`; no runtime validation, the
    schema is for the model only). All three runtime shapes go through
    `Jido.Action.Schema.validate/2`
    ([action/schema.ex:62–70](../../lib/jido/action/schema.ex)), which
    dispatches by shape. The polyglot is intentional at the layer boundaries —
    Spark.Options for compile-time DSL, Zoi for runtime data + structs,
    NimbleOptions as one of three accepted action-input shapes, JSON Schema as
    an LLM-tool passthrough. Whether to consolidate runtime is captured in
    [ADR 0024](0024-schema-language-consolidation.md) (open).
- **Compile-time errors get clearer.** Spark's error messages cite the file/line
  of the offending DSL entity, which our raw `Zoi.parse` in
  `__quoted_compile_options__/1` does not. Authoring agents stops being a
  guessing game.
- **Pod and `Jido` instance modules.** `lib/jido.ex` and `lib/jido/pod.ex`
  migrate too — the same Spark-DSL treatment applies. The pod module's
  `topology` resolution becomes a Spark transformer; the `Jido` instance
  module's `default_slices` lookup becomes a Spark verifier.

## Alternatives considered

- **Keep the hand-rolled macros, just clean them up.** Possible but doesn't
  solve the extension story. The slice DSL contribution ("let `Jido.AI.ReAct`
  add a `react do … end` section to the host agent") is hard to do without a
  real DSL framework — we'd be rebuilding Spark badly. Rejected.
- **Use `nimble_options` directly without Spark.** Saves the dep but loses the
  section / entity / extension model; we'd still hand-roll the macros that turn
  validated options into module attributes and the introspection surface that
  lets one module discover another's DSL contribution. The cost of writing that
  ourselves badly outweighs the cost of one well-supported dep. Rejected.
- **Build a small DSL layer in-tree.** Same objection as above, plus it's now
  framework code we maintain. Rejected.
- **Migrate only the agent and slice surfaces; leave action / sensor alone.**
  Possible — `use Jido.Action` and `use Jido.Sensor` are smaller surfaces and
  don't have an extension story. Rejected because (a) authoring consistency
  matters more than any one surface; (b) the `:schema` / `:output_schema` /
  `:path` / `:compensation` / `:tags` keyword soup in `lib/jido/action.ex` is
  exactly the case where Spark's structured sections shine; (c) one cohesive
  migration is cheaper than two.
- **Make slices a runtime extension** (loaded via `Application.get_env` rather
  than declared in the agent module). Rejected: it breaks the compile-time
  validation guarantees ADR 0014 was designed around, it loses the "the agent
  module is the spec" property that makes jido modules readable, and it creates
  a startup ordering problem that has nothing to do with the original problem.

## Follow-ups (out of this ADR's scope, captured for the tasks)

- The `Jido.AI.ReAct` slice
  ([task 0030](../tasks/0030-llm-agent-slice-composition-refactor.md)) picks up
  its own `react do … end` section as part of
  [task 0041](../tasks/0041-extensions-contribute-dsl-sections.md).
- The migration guide entry lives in `guides/migration.md`; the generated cheat
  sheets live in `documentation/dsls/` (Spark's default output dir).
- `mix spark.formatter --extensions Jido.Dsl.Agent,Jido.Dsl.Slice,…` runs in CI;
  the resulting `.formatter.exs` updates ship in
  [task 0042](../tasks/0042-docs-and-cleanup.md).
- Igniter recipes (`mix jido.gen.agent`, `mix jido.gen.slice`) are out of scope
  here — Spark makes them straightforward to add later but they are not required
  for this ADR to land.
