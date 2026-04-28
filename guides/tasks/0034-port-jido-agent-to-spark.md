---
name: Task 0034 — Port `use Jido.Agent` and `use Jido` to Spark DSL
description: Replace `Jido.Agent`'s 345-line `__using__` macro and Zoi `@agent_config_schema` with a Spark DSL defined in `Jido.Dsl.Agent`. Host-owned sections — `agent`, `signal_routes`, `schedules`. Per-extension typed blocks (`memory do`, `react do`, `retry do`, …) are owned by the contributing modules listed in `use Jido.Agent, extensions: [...]` (per ADR 0023 §3). A single `WalkExtensions` transformer reads each registered extension's typed section, classifies it by marker (`__jido_slice__` / `__jido_plugin__` / `Jido.Middleware`), and produces the same internal `slices` / `plugins` / `middleware` lists today's macro builds — chain order from the `extensions: [...]` keyword. Public runtime API (`new/1`, `cmd/2`, `set/2`, `validate/2`, `signal_routes/0`, `actions/0`, `plugins/0`, `slices/0`, `middleware/0`, …) keeps its current shape. Same treatment for `lib/jido.ex`'s `use Jido` macro via `Jido.Dsl.Instance`. Every in-tree agent module (Pod, AI, tests, examples) rewrites to the new DSL in this commit; tree red until task 0035 lands.
---

# Task 0034 — Port `use Jido.Agent` and `use Jido` to Spark DSL

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1, §2, §3, §6.
- Depends on: [task 0033](0033-spark-dep-and-jido-dsl-scaffold.md).
- Blocks: [task 0035](0035-port-slice-plugin-middleware-to-spark.md).
- Leaves tree: **red** (slice / plugin / middleware / action / sensor still use the legacy macros; they still compile because they don't depend on the agent's DSL, but examples and integration tests that compose them with agents fail until 0035–0036 land).

## Context

`lib/jido/agent.ex` is the largest single chunk of compile-time
machinery in the framework: a `defmacro __using__/1` that calls
eleven `__quoted_*__/0` helper functions, plus the
`@agent_config_schema` Zoi schema, plus
`__quoted_compile_options__/1`, plus
`__quoted_compile_instances__/0`, plus
`__quoted_compile_aggregates__/0`. ADR 0023 §1 calls for replacing
this with a Spark DSL.

The runtime API (`MyAgent.new/1`, `cmd/2`, `set/2`,
`signal_routes/0`, `actions/0`, …) does not change. What changes is
**how the user writes the module** and **how the framework derives
compile-time aggregates** — both of those move into Spark.

`lib/jido.ex`'s `use Jido` macro (`otp_app:`, `storage:`,
`default_slices:`) gets the same treatment via `Jido.Dsl.Instance`,
because the DSL story is consistent or it is not interesting.

## Goal

After this commit:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent,
    extensions: [
      MyApp.MemorySlice,
      MyApp.SlackPlugin,
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
    route "user.created", MyApp.HandleUserCreated
    route "payment.*", MyApp.LargePayment, priority: 10, match: &(&1.data.amount > 100)
  end

  schedules do
    schedule "*/5 * * * *", "tick.heartbeat"
  end

  # typed block contributed by MyApp.MemorySlice
  memory do
    namespace :support
  end

  # typed block contributed by MyApp.SlackPlugin
  slack do
    channel "#ops"
  end

  # typed block contributed by Jido.Middleware.Retry
  retry do
    max_retries 3
  end

  # MyApp.AuditPlugin has no required config; its block is omitted.
end
```

The `extensions: [...]` keyword on `use Jido.Agent` is the single
ordered registration list per [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §3:

- The **`extensions: [...]` keyword-list order** is the
  middleware-chain order for plugin (middleware halves) and
  middleware entries. Slice entries do not participate in the chain
  — they mount at the slice's `path()`.
- **Kind is inferred from the module's markers** at compile time —
  `__jido_plugin__/0` → plugin, `__jido_slice__/0` only → slice,
  `Jido.Middleware` behaviour only → middleware. Modules matching
  none raise `CompileError` at the host's compile time.
- **Override (rare): `{Mod, as: :slice}`** in the keyword list
  forces a plugin module to mount slice-only. Bad overrides
  (`{BareSlice, as: :plugin}`) raise.

`MyApp.SupportAgent.signal_routes/0`, `.plugins/0` (entries
classified as `:plugin`), `.slices/0` (entries classified as
`:slice`), `.middleware/0` (entries classified as `:middleware`, in
chain order), `.actions/0`, `.path/0`, `.schema/0`, `.cmd/2`,
`.new/1` all return the same shapes they return today. The
accessors are filter projections over the registered extensions.

## Files to modify

### `lib/jido/agent.ex`

1. Delete `defmacro __using__/1` (lines ~1092–1121) and every
   `__quoted_*__/0` helper (lines ~393–1090). The `__resolve_default_slices__/1`,
   `__seed_own_slice__/2`, `__seed_plugin_slice__/2`,
   `__normalize_plugin_instances__/1`, and
   `__normalize_slice_instances__/1` *runtime helpers* stay — they're
   called from generated code.

2. Replace the body of `__using__/1` with a Spark passthrough:

   ```elixir
   defmacro __using__(opts) do
     quote do
       use Spark.Dsl,
         default_extensions: [extensions: [Jido.Dsl.Agent]],
         opt_schema: [
           extensions: [type: {:list, :atom}, default: []]
         ]

       # any extension passed via `use Jido.Agent, extensions: […]`
       # additionally registers, processed by Spark
       Module.put_attribute(__MODULE__, :jido_user_extensions, unquote(opts[:extensions] || []))
     end
   end
   ```

   The actual section / entity definitions live in
   `Jido.Dsl.Agent`; everything Spark sees flows through there.

3. Keep the `@agent_config_schema` *Zoi* schema for runtime validation
   of `Agent.new/1` arguments (the struct schema, not the DSL schema).
   The DSL schema in `Jido.Dsl.Agent` is `nimble_options`-shaped; the
   runtime schema in `Jido.Agent` is Zoi-shaped. Both coexist, each
   doing what it is good at.

### `lib/jido/dsl/agent.ex`

Replace the placeholder with the full DSL:

```elixir
defmodule Jido.Dsl.Agent do
  @agent_section %Spark.Dsl.Section{
    name: :agent,
    schema: [
      name: [type: {:custom, Jido.Util, :validate_name, []}, required: true,
             doc: "Agent name (letters, numbers, underscores)."],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string],
      path: [type: :atom, required: true,
             doc: "Atom slice key where the agent's user-domain state lives."],
      schema: [type: :any, default: [],
               doc: "Zoi or NimbleOptions schema for the agent's slice state."]
    ]
  }

  @route %Spark.Dsl.Entity{
    name: :route,
    target: Jido.Signal.Router.Route,
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

  @schedule %Spark.Dsl.Entity{
    name: :schedule,
    target: Jido.Agent.Schedules.Spec,
    args: [:cron, :signal_type],
    schema: [
      cron: [type: :string, required: true],
      signal_type: [type: :string, required: true],
      data: [type: :map, default: %{}]
    ]
  }

  @schedules_section %Spark.Dsl.Section{
    name: :schedules,
    entities: [@schedule]
  }

  use Spark.Dsl.Extension,
    sections: [
      @agent_section,
      @signal_routes_section,
      @schedules_section
    ],
    transformers: [
      Jido.Dsl.Agent.Transformers.WalkExtensions,
      Jido.Dsl.Agent.Transformers.MergeSchemas,
      Jido.Dsl.Agent.Transformers.ExpandRoutes,
      Jido.Dsl.Agent.Transformers.ValidateRequirements,
      Jido.Dsl.Agent.Transformers.GenerateAccessors
    ],
    verifiers: [
      Jido.Dsl.Agent.Verifiers.UniquePaths,
      Jido.Dsl.Agent.Verifiers.NoSingletonAlias,
      Jido.Dsl.Agent.Verifiers.NoRouteConflicts,
      Jido.Dsl.Agent.Verifiers.NoSectionNameCollisions
    ]
end
```

There is **no host-level `extensions` section**. The
`extensions: [...]` keyword on `use Jido.Agent` is Spark-native:
`use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Agent]],
opt_schema: [extensions: [type: {:list, :any}, default: []]]`. Each
module passed in `extensions: [...]` (or in `{Module, opts}` form
for the rare override) is itself a `Spark.Dsl.Extension`, and
Spark adds its sections to the host automatically.

The single new transformer that classifies extensions:

- `WalkExtensions` — for each module in the keyword list:
  1. Resolve the module (handle `Mod` vs `{Mod, as: :slice}` forms).
  2. Inspect markers: `function_exported?(module, :__jido_plugin__, 0)`,
     `__jido_slice__/0`, and `Jido.Middleware` behaviour.
  3. Apply explicit `as:` override if present, validating against
     markers (e.g. `as: :plugin` on a bare slice raises citing the
     missing `__jido_plugin__/0`).
  4. Build a `Jido.Slice.Instance`, `Jido.Plugin.Instance`, or
     `{module, opts_map}` (for middleware) — pulling that module's
     **typed-section config** out of the host DSL state via
     `Spark.Dsl.Extension.get_opt(dsl_state, [section_name], …)`.
  5. Append to `dsl_state[:slices]` / `[:plugins]` / `[:middleware]`,
     preserving keyword-list order in each list.

Downstream transformers (`MergeSchemas`, `ExpandRoutes`,
`ValidateRequirements`, `GenerateAccessors`) read from those split
lists exactly as today's `__quoted_compile_instances__/0` /
`__quoted_compile_aggregates__/0` read from
`@validated_opts[:plugins]`, `[:slices]`, and `[:middleware]`.

The chain composer in `Jido.AgentServer` (today's
`compose_chain/1`) reads `MyAgent.middleware/0` and
`MyAgent.plugin_instances/0` — both in `extensions: [...]` keyword
order — and concatenates per ADR 0014 §"Middleware chain
composition", except that "declaration order" is now a single
source of truth (the keyword list).

The new verifier `NoSectionNameCollisions` rejects two extensions
contributing the same section name (e.g. two libraries both
exposing `:react do … end`); the error names both modules.

### `lib/jido/dsl/agent/transformers/*.ex`

One transformer per current `__quoted_compile_*__` block:

- `NormalizeSlices` — replaces `__normalize_slice_instances__/1` and
  pulls user-supplied `extensions:` slices into the DSL state.
- `NormalizePlugins` — replaces `__normalize_plugin_instances__/1`.
- `MergeSchemas` — replaces the `Jido.Agent.Schema.merge_with_plugins`
  call site in `__quoted_compile_aggregates__/0`.
- `ExpandRoutes` — replaces the `expand_routes` block.
- `ValidateRequirements` — replaces the `Jido.Plugin.Requirements.validate_all_requirements`
  block.
- `GenerateAccessors` — emits the `def name`, `def path`, `def
  signal_routes`, `def plugins`, `def slices`, `def actions`, `def
  capabilities`, `def signal_types`, `def plugin_routes`, `def
  plugin_schedules`, `def __agent_metadata__`, etc. that
  `__quoted_basic_accessors__/0`, `__quoted_plugin_accessors__/0`,
  and `__quoted_plugin_config_accessors__/0` generate today. These
  read from the validated DSL state via `Spark.Dsl.Extension.get_persisted/2`.

### `lib/jido/dsl/agent/verifiers/*.ex`

- `UniquePaths` — replaces the duplicate-path raise in
  `__quoted_compile_instances__/0`.
- `NoSingletonAlias` — replaces the singleton-alias raise.
- `NoRouteConflicts` — replaces `Jido.Plugin.Routes.detect_conflicts/1`
  raise.
- `NoSectionNameCollisions` — new. Rejects two extensions
  contributing the same section name (per ADR 0023 §3).

### Internal extension-list shape (no new struct needed)

`WalkExtensions` produces three lists under the existing struct
types: `Jido.Slice.Instance`, `Jido.Plugin.Instance`, and
`{module, opts_map}` for middleware. The downstream transformers
consume them exactly as today's macro consumes
`@validated_opts[:plugins]` / `[:slices]` / `[:middleware]`.
Existing call sites in `Jido.AgentServer` that read
`middleware: [Mod | {Mod, opts}]` and `plugins:` / `slices:` lists
keep their current shape — the only change is *where the lists come
from*.

### `lib/jido.ex`

Apply the same treatment:

```elixir
defmodule Jido do
  use Supervisor

  defmacro __using__(opts) do
    quote do
      use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Instance]]

      Module.put_attribute(__MODULE__, :jido_otp_app, unquote(opts[:otp_app]))
    end
  end

  # ... rest of the runtime code (start_link/1, init/1, etc.) stays as is
end
```

`Jido.Dsl.Instance` defines the equivalent of today's `:otp_app`,
`:storage`, `:default_slices` options:

```elixir
@instance_section %Spark.Dsl.Section{
  name: :instance,
  schema: [
    otp_app: [type: :atom, required: true],
    storage: [type: :any, default: {Jido.Storage.ETS, [table: :jido_storage]}],
    default_slices: [type: :any]
  ]
}
```

Plus a transformer that emits the runtime accessors
(`__otp_app__/0`, `__jido_storage__/0`, `__default_slices__/0`,
`config/1`, `start_agent/2`, …) the current macro generates.

### Every in-tree agent module

Rewrite to the sectioned DSL:

- `lib/jido/pod.ex`'s inner `use Jido.Agent, …` (line 87) — the pod
  macro continues to wrap, but the wrapped agent block becomes the
  sectioned form.
- `lib/jido/ai.ex` (the `use Jido.Agent` example in the moduledoc;
  no actual agent module here, just docs).
- `test/support/*` — every test agent module.
- Every agent module under `test/jido/` and `test/examples/`.

A representative migration for a test agent:

```elixir
# before
defmodule TestAgent do
  use Jido.Agent,
    name: "test",
    path: :domain,
    schema: [counter: [type: :integer, default: 0]],
    plugins: [{MyApp.SlackPlugin, %{channel: "#ops"}}],
    middleware: [{Jido.Middleware.Retry, %{max_retries: 3}}]
end

# after
defmodule TestAgent do
  use Jido.Agent,
    extensions: [
      Jido.Middleware.Retry,
      MyApp.SlackPlugin
    ]

  agent do
    name "test"
    path :domain
    schema [counter: [type: :integer, default: 0]]
  end

  retry do
    max_retries 3
  end

  slack do
    channel "#ops"
  end
end
```

The chain-order convention "middleware first, then plugin
middleware halves" carries over by listing middleware before
plugins in `extensions: [...]`. Users who want to interleave
(e.g., a plugin's middleware running *before* a bare middleware)
just reorder the keyword list. The migration is mechanical; a
`git grep -l "use Jido.Agent,"` enumerates every site.

### `lib/jido/agent_server.ex`

Reads `MyAgent.middleware/0`, `MyAgent.signal_routes/0`,
`MyAgent.plugins/0`, `MyAgent.slices/0`, `MyAgent.path/0`. **No
changes** — those accessors keep their shapes; only their definition
moves from `__quoted_*__/0` to a Spark transformer.

If any callsite reads from a private attribute like
`@plugin_instances` directly (it shouldn't), refactor to use the
public accessor first.

## Files to create

- `lib/jido/dsl/agent/transformers/walk_extensions.ex`
- `lib/jido/dsl/agent/transformers/merge_schemas.ex`
- `lib/jido/dsl/agent/transformers/expand_routes.ex`
- `lib/jido/dsl/agent/transformers/validate_requirements.ex`
- `lib/jido/dsl/agent/transformers/generate_accessors.ex`
- `lib/jido/dsl/agent/verifiers/unique_paths.ex`
- `lib/jido/dsl/agent/verifiers/no_singleton_alias.ex`
- `lib/jido/dsl/agent/verifiers/no_route_conflicts.ex`
- `lib/jido/dsl/agent/verifiers/no_section_name_collisions.ex`
- `lib/jido/dsl/instance.ex` (full DSL — replaces task 0033 placeholder)
- `lib/jido/dsl/instance/transformers/generate_accessors.ex`
- `test/jido/dsl/agent_test.exs`
- `test/jido/dsl/agent_extensions_order_test.exs` — covers the
  middleware-chain ordering with mixed plugin / middleware entries
  in `extensions: [...]`, asserts `compose_chain/1` wraps in
  keyword-list order.
- `test/jido/dsl/agent_kind_inference_test.exs` — covers kind
  inference from markers, the rare `{Mod, as: :slice}` override,
  marker-mismatch errors.
- `test/jido/dsl/instance_test.exs`

## Files to delete

None. The old `__quoted_*__/0` helpers are *replaced* in place by the
Spark transformers; the helpers themselves disappear from
`lib/jido/agent.ex` as part of step (1) above.

## Acceptance

- `mix compile --warnings-as-errors` clean for `lib/`. Tests may
  fail for slice / plugin / middleware / action / sensor surfaces
  that haven't migrated yet — that's why this task is marked **red**.
  The agent surface itself compiles clean.
- A representative test (`test/jido/dsl/agent_test.exs`) covers:
  1. `use Jido.Agent` with a full sectioned DSL produces the same
     `signal_routes/0` / `plugins/0` / `slices/0` / `actions/0` /
     `path/0` outputs as the legacy keyword form did.
  2. `Agent.new/1` still seeds slice state correctly.
  3. `Agent.cmd/2` still routes through the slice machinery.
  4. Compile-time errors for duplicate paths, singleton aliasing, and
     route conflicts still raise (verifiers fire).
- `mix test test/jido/dsl/` clean.

## Out of scope

- Section / entity definitions for `use Jido.Slice`, `use Jido.Plugin`,
  `use Jido.Middleware`. Task 0035.
- Section / entity definitions for `use Jido.Action`, `use Jido.Sensor`.
  Task 0036.
- Letting **slices** contribute their own sections to the host agent
  (the Ash-style extension story). Task 0037.
- Generated docs / cheat sheets. Task 0038.

## Risks

- **Chain-order regression.** [ADR 0014](../adr/0014-slice-middleware-plugin.md)
  §"Middleware chain composition" defined the chain as
  `middleware ++ plugin_middleware_in_declaration_order`. Under the
  new shape, the chain is the order of plugin / middleware entries
  in the `extensions: [...]` keyword list. For agents that
  previously had both `middleware:` and `plugins:` filled, the
  migration must list middleware before plugins to preserve "all
  middleware first, then all plugin middleware halves" unless the
  user chooses to interleave. Add a regression test that exercises
  the canonical order.
- **Surface area.** Every in-tree agent module rewrites in this
  commit. The diff is large but mechanical. Review by section.
- **Generated accessor parity.** The `GenerateAccessors` transformer
  must emit exactly the functions today's `__quoted_*__/0` helpers
  emit, with the same shapes. Pin this with a property test that
  takes a representative agent module and asserts every public
  accessor is exported with the same arity.
- **`@plugin_instances`, `@slice_instances`, `@expanded_signal_routes`,
  `@merged_schema` module attributes.** Today these are set as
  module attributes; downstream code (e.g. some accessors) reads
  them directly via `@`. After the migration they live in the Spark
  DSL state, accessed via `Spark.Dsl.Extension.get_persisted/2`. The
  `GenerateAccessors` transformer must emit the same module
  attributes for any callsite that still expects them — easier than
  hunting every `@plugin_instances` reader.
- **`Jido.Pod.__using__/1`.** Pod's macro wraps the agent macro; that
  wrap must thread the sectioned DSL correctly. Confirm a pod-wrapped
  test passes end-to-end before declaring this task done. Note: pod's
  own DSL surface (`topology`, etc.) lands in task 0036 if it has
  configurable options worth a section, otherwise it stays a runtime
  attribute.
- **Tests for `__quoted_callback_overridables__/0`.** The `defoverridable`
  list moves into the `GenerateAccessors` transformer; user agents
  that override `signal_routes/0` etc. must still work.
- **Spark internals churn between minor versions.** Pin `~> 2.2` and
  re-run the test suite when bumping; the public Spark API is stable
  but transformer / verifier signatures occasionally evolve.
