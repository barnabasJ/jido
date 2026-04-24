# Task 0005 — Rewrite `Jido.Plugin` macro; migrate in-tree plugins; flip `default_plugins` to path-keyed

- Commit #: 5 of 9
- Implements: [ADR 0014](../adr/0014-slice-middleware-plugin.md) — plugin author surface migration, in-repo consumers
- Depends on: 0000, 0001, 0002, 0003, 0004
- Blocks: 0006
- Leaves tree: **red** (plugin-related tests still need updates until C8)

## Goal

Three paired changes land together in this commit:

1. **Rewrite `Jido.Plugin` macro** to be `use Jido.Slice + use Jido.Middleware` combo. Delete the old callback surface entirely from the macro.
2. **Migrate the 5 in-tree plugin files** (Thread, Identity, Memory, Pod, BusPlugin) to the new shape — `use Jido.Slice` or `use Jido.Plugin`, drop old `state_key: :__foo__` → `path: :foo`, remove orphan callback bodies.
3. **Flip `default_plugins` override map** from `state_key`-keyed to `path`-keyed (`%{__thread__: false}` → `%{thread: false}`).

All three depend on each other: rewriting the macro breaks every caller; migrating callers without the macro rewrite is incoherent; flipping default_plugins keys without the plugin path rename produces broken lookups. Pairing them in one commit is the clean move.

After this task: the entire plugin surface is Slice/Plugin; no in-tree module still depends on the legacy callback vocabulary.

## Files to rewrite

### `lib/jido/plugin.ex` — **macro rewrite**

Replace today's callback-generating macro with:

```elixir
defmodule Jido.Plugin do
  @moduledoc """
  A Plugin is a composable capability — Slice + Middleware in one module.
  `use Jido.Plugin, opts` expands to `use Jido.Slice, opts` + `use Jido.Middleware`.
  """

  defmacro __using__(opts) do
    quote do
      use Jido.Slice, unquote(opts)
      use Jido.Middleware
    end
  end
end
```

Delete these from the module (lines from today's file):
- `@callback mount/2` ([lines 217-218](../../lib/jido/plugin.ex))
- `@callback signal_routes/1` (dynamic variant)
- `@callback handle_signal/2` ([lines 261-262](../../lib/jido/plugin.ex))
- `@callback transform_result/3` ([lines 292-293](../../lib/jido/plugin.ex))
- `@callback child_spec/1` ([lines 320-321](../../lib/jido/plugin.ex))
- `@callback subscriptions/2` (dynamic variant)
- `@callback on_checkpoint/2`, `@callback on_restore/2` ([lines 387-413](../../lib/jido/plugin.ex))
- All default implementations ([lines 617-660](../../lib/jido/plugin.ex))
- The `defoverridable` block ([lines 665-693](../../lib/jido/plugin.ex))

The module becomes tiny — just the combo macro and a one-line moduledoc.

## Files to rewrite

### `lib/jido/thread/plugin.ex` → **Jido.Slice** + `Jido.Persist.Transform` behaviour

Path: `:thread`. The Slice itself declares `@behaviour Jido.Persist.Transform` (see the Persister middleware section below) so `externalize/1` and `reinstate/1` live alongside the slice's declaration. Persister middleware walks all declared slices/plugins and applies these callbacks where present. No separate `Jido.Thread.Persister` module; no `transforms:` map in Persister opts.

```elixir
defmodule Jido.Thread.Plugin do
  use Jido.Slice,
    name: "thread",
    path: :thread,
    actions: [],
    singleton: true,
    description: "Thread state management for agent conversation history.",
    capabilities: [:thread]
    # schema is nil — thread is attached on demand by Jido.Thread.Agent

  @behaviour Jido.Persist.Transform

  # On hibernate: flush journal entries synchronously, return a small pointer.
  @impl Jido.Persist.Transform
  def externalize(%Jido.Thread{id: id, rev: rev, entries: entries}) do
    :ok = Jido.Thread.Journal.flush(id, entries)
    %{id: id, rev: rev}
  end
  def externalize(nil), do: nil

  # On thaw: rehydrate the Thread struct from the pointer.
  @impl Jido.Persist.Transform
  def reinstate(%{id: id, rev: rev}) do
    case Jido.Thread.Store.fetch(id, rev) do
      {:ok, thread} -> thread
      {:error, _} -> nil
    end
  end
  def reinstate(nil), do: nil
end
```

Agents declaring Thread + Persister just configure storage; no transform wiring needed:

```elixir
use Jido.Agent, ...
  plugins: [Jido.Thread.Plugin],
  middleware: [
    {Jido.Middleware.Persister, %{
      storage: {MyStorage, opts},
      persistence_key: "my-agent"
    }}
  ]
```

The old `on_checkpoint/2` and `on_restore/2` callbacks disappear — replaced by the `Jido.Persist.Transform` behaviour declared directly on slices that need custom serialization.

[lib/jido/thread/agent.ex](../../lib/jido/thread/agent.ex) `@key :__thread__` → `@key :thread`. Update `ensure/2`, `has_thread?/1`, `get_thread/1`, and any read site.

### `lib/jido/identity/plugin.ex` → **Jido.Slice**

Pure Slice. No middleware half.

```elixir
defmodule Jido.Identity.Plugin do
  use Jido.Slice,
    name: "identity",
    path: :identity,
    actions: [],
    singleton: true,
    description: "Identity state management for agent self-model.",
    capabilities: [:identity]
end
```

[lib/jido/identity/agent.ex](../../lib/jido/identity/agent.ex) `@key :__identity__` → `@key :identity`. Update all reads.

### `lib/jido/memory/plugin.ex` → **Jido.Slice**

Pure Slice. No middleware half. No persistence externalization.

```elixir
defmodule Jido.Memory.Plugin do
  use Jido.Slice,
    name: "memory",
    path: :memory,
    actions: [],
    singleton: true,
    description: "Memory state management for agent cognitive state.",
    capabilities: [:memory]
end
```

[lib/jido/memory/agent.ex](../../lib/jido/memory/agent.ex) `@key :__memory__` → `@key :memory`. Update all reads.

### `lib/jido/pod/plugin.ex` → **Jido.Plugin**

Path: `:pod`. Middleware half handles reconcile-at-start.

```elixir
defmodule Jido.Pod.Plugin do
  use Jido.Plugin,
    name: "pod",
    path: :pod,
    actions: [MutateAction, QueryNodes, QueryTopology],
    signal_routes: [
      {"mutate", MutateAction},
      {"jido.pod.query.nodes", QueryNodes},
      {"jido.pod.query.topology", QueryTopology}
    ],
    schema: Zoi.object(%{
      topology: Zoi.any() |> Zoi.optional(),
      topology_version: Zoi.integer() |> Zoi.default(1),
      mutation: Zoi.object(%{...}) |> Zoi.default(%{...}),
      metadata: Zoi.map() |> Zoi.default(%{})
    }),
    capabilities: [:pod],
    singleton: true

  # Middleware observes lifecycle.starting to run reconcile before ready.
  # Four-arg callback per C0: on_signal(sig, ctx, opts, next).
  @impl Jido.Middleware
  def on_signal(%Signal{type: "jido.agent.lifecycle.starting"} = sig, ctx, _opts, next) do
    {new_ctx, dirs} = next.(sig, ctx)
    # Reconcile reads topology from the pod slice in new_ctx.agent.state.pod
    Jido.Pod.Runtime.reconcile(new_ctx, ...)
    {new_ctx, dirs}
  end

  def on_signal(sig, ctx, _opts, next), do: next.(sig, ctx)
end
```

`mount/2` in today's file ([lines 92-104](../../lib/jido/pod/plugin.ex)) is gone. Per S2 resolution, topology seeding moves to the **`use Jido.Pod` macro** on the agent module, which overrides `new/1` to inject pod state before calling the base `Agent.new/1`:

```elixir
# lib/jido/pod.ex — macro generates:
defmacro __using__(opts) do
  quote do
    use Jido.Agent, unquote(agent_opts_with_pod_plugin(opts))
    @pod_topology unquote(opts[:topology])
    def topology, do: @pod_topology

    defoverridable new: 1

    def new(opts \\ []) do
      pod_state = Jido.Pod.Plugin.build_state(topology(), %{})
      initial_state =
        opts
        |> Keyword.get(:state, %{})
        |> Map.put_new(:pod, pod_state)

      super(Keyword.put(opts, :state, initial_state))
    end
  end
end
```

Result: `MyApp.Fulfillment.new()` returns an agent struct with `agent.state.pod == %{topology: %Topology{...}, topology_version: 1, mutation: %{...}, metadata: %{}}` immediately — no AgentServer needed. Standalone `cmd/2` works in tests.

**`Jido.Pod.Plugin.build_state/2`** ([pod/plugin.ex:54-77](../../lib/jido/pod/plugin.ex)) is retained as a pure helper called by the macro. No behavior change to it.

**Agent.new/1 extension needed**: today `Agent.new/1`'s `state:` option only seeds the agent's own slice (at `agent.state[agent_module.path()]`). Extend it in this commit to also accept plugin-slice keys in the state map, merged with the plugin's schema defaults. So `Agent.new(state: %{pod: %{topology: ...}})` seeds `agent.state.pod`. Same merge rule applied to every declared plugin's slice key.

**Where this lives in [lib/jido/agent.ex](../../lib/jido/agent.ex)**: the current `def new/1` at [line 773](../../lib/jido/agent.ex) calls `__build_initial_state__(opts)` then `__mount_plugins__(agent)`. Both helpers change:

- `__mount_plugins__/1` — **deleted**. `mount/2` retires (S2 resolution); its per-case replacements land elsewhere (macro override, schema default, lifecycle.starting routing).
- `__build_initial_state__/1` — **extended** to seed plugin slices:

```elixir
defp __build_initial_state__(opts) do
  user_state = opts[:state] || %{}

  # 1. Seed the agent's own slice. Zoi.parse/2 fills defaults AND validates in one step.
  own_path = path()
  own_user = Map.get(user_state, own_path, %{})
  own_slice = seed_slice!(schema(), own_user)

  # 2. Seed each declared plugin's slice (NEW in this commit).
  plugin_slices =
    plugins()
    |> Enum.map(&normalize_plugin_entry/1)   # {mod, config_map} regardless of input shape
    |> Enum.reduce(%{}, fn {mod, config}, acc ->
      p = mod.path()
      user = Map.get(user_state, p, %{})
      # Shallow-merge: config < user override (top-level keys replace atomically).
      # Zoi.parse then fills any missing keys from schema defaults + validates.
      merged_input = Map.merge(config, user)
      slice = seed_slice!(mod.schema(), merged_input)
      Map.put(acc, p, slice)
    end)

  # 3. Path-uniqueness check: agent.path() + each plugin.path() must all be distinct.
  assert_paths_unique!(own_path, plugins())

  # 4. Combine.
  Map.put(plugin_slices, own_path, own_slice)
end

defp normalize_plugin_entry({mod, config}) when is_atom(mod) and is_map(config), do: {mod, config}
defp normalize_plugin_entry(mod) when is_atom(mod), do: {mod, %{}}

defp assert_paths_unique!(own_path, plugins) do
  all = [own_path | Enum.map(plugins, fn
    {mod, _} -> mod.path()
    mod      -> mod.path()
  end)]

  case all -- Enum.uniq(all) do
    [] -> :ok
    dupes -> raise Jido.Agent.PathConflictError, paths: Enum.uniq(dupes)
  end
end

# Zoi.parse/2 handles defaults + validation in one call: missing keys with Zoi.default(v)
# get v; present keys get validated. No separate Zoi.defaults call needed (doesn't exist).
defp seed_slice!(nil, value), do: value
defp seed_slice!(schema, value) do
  case Zoi.parse(schema, value) do
    {:ok, validated} -> validated
    {:error, err}    -> raise Jido.Agent.SliceValidationError, message: err
  end
end
```

**Shape accepted in `plugins:`**: `[module() | {module(), map()}]`. Bare module ⇒ `config = %{}`. Plugin schema defaults + config + user-override flow through shallow merge.

**New errors**:
- `Jido.Agent.PathConflictError` — two slices declaring the same `path:`.
- `Jido.Agent.SliceValidationError` — schema validation failed for a seeded slice.

Both raised at `Agent.new/1` (compile-time + early-runtime), not at signal-handling time.

**Uniqueness checks are orthogonal**: `PathConflictError` fires when two different modules both declare the same `path:` (build-time guard here in `Agent.new/1`). `DuplicatePluginError` (task 0004) fires when the same module appears twice across compile-time middleware + runtime `Options.middleware:` + compile-time plugin middleware halves (init-time guard in `build_middleware_chain`). Both raise fail-fast at agent/server construction; no silent double-registration.

**Merge semantics — shallow, schema-validated**:
- Apply Zoi schema defaults to produce a per-slice default map (e.g., `%{topology: nil, topology_version: 1, mutation: %{}, metadata: %{}}`).
- Shallow-merge user-provided config on top: top-level keys in the user's map replace schema defaults atomically. Nested values are NOT deep-merged — passing `%{mutation: %{x: 1}}` replaces the whole `mutation` map, it doesn't merge into the schema-default `mutation`.
- Validate the merged result against the Slice's schema. Raise on validation failure.
- This matches how "init with defaults" works in Ecto changesets and Phoenix config; avoids deep-merge footguns (list concatenation, struct overlap, nil handling). Plugin authors with nested config document that users should pass complete sub-structures.

**Path uniqueness**: `Agent.new/1` must also verify that no two declared slices/plugins share a `path:` — including collision with `agent_module.path()`. Raise at `Agent.new/1` with `Jido.Agent.PathConflictError` listing the offending modules.

**No runtime plugin injection**: per round-4 pivot, `Options.plugins:` was dropped. Compile-time `plugins:` on the agent module stays (for user-defined Plugins with slice state). Persister, the only in-repo user of runtime injection before the pivot, is middleware-only now and injects via `Options.middleware:` instead. No `merge_runtime_plugin_configs` helper; `Agent.new/1` processes only the compile-time-declared plugins.

### `lib/jido/middleware/persister.ex` — **middleware only** (per W7 + round-4 pivot)

A `Jido.Middleware` module — no Slice, no agent.state footprint. Persister is pure infrastructure: its config (storage, persistence_key, transforms) lives in the middleware's `opts` arg, captured by closure at chain-build time. On `lifecycle.starting` / `lifecycle.stopping`, the middleware **blocks synchronously** on `Jido.Persist.thaw/hibernate` IO and mutates `ctx.agent` with the thawed struct before calling `next`. No directives, no executors, no slice.

```elixir
defmodule Jido.Middleware.Persister do
  use Jido.Middleware

  alias Jido.Agent.Directive
  alias Jido.Signal

  # opts schema (compile-time or runtime-injected):
  #   %{
  #     storage: {adapter_module, adapter_opts} | nil,
  #     persistence_key: term(),
  #     transforms: %{path => {mod, externalize_fun, reinstate_fun}}
  #   }
  # When storage is nil the middleware is pass-through — no-op for every signal.

  # Thaw on starting.
  def on_signal(%Signal{type: "jido.agent.lifecycle.starting"} = sig, ctx, opts, next) do
    case opts[:storage] do
      nil ->
        next.(sig, ctx)

      storage ->
        case Jido.Persist.thaw(storage, ctx.agent_module, opts[:persistence_key]) do
          {:ok, raw_agent} ->
            thawed_agent = apply_reinstate(raw_agent, ctx.agent_module)
            {final_ctx, dirs} = next.(sig, %{ctx | agent: thawed_agent})
            {final_ctx, dirs ++ [emit("jido.persist.thaw.completed", %{persistence_key: opts[:persistence_key]})]}

          {:error, reason} ->
            {final_ctx, dirs} = next.(sig, ctx)
            {final_ctx, dirs ++ [emit("jido.persist.thaw.failed", %{reason: reason, persistence_key: opts[:persistence_key]})]}
        end
    end
  end

  # Hibernate on stopping.
  def on_signal(%Signal{type: "jido.agent.lifecycle.stopping"} = sig, ctx, opts, next) do
    case opts[:storage] do
      nil ->
        next.(sig, ctx)

      storage ->
        to_serialize = apply_externalize(ctx.agent, ctx.agent_module)
        case Jido.Persist.hibernate(storage, ctx.agent_module, opts[:persistence_key], to_serialize) do
          :ok ->
            {final_ctx, dirs} = next.(sig, ctx)
            {final_ctx, dirs ++ [emit("jido.persist.hibernate.completed", %{persistence_key: opts[:persistence_key]})]}

          {:error, reason} ->
            {final_ctx, dirs} = next.(sig, ctx)
            {final_ctx, dirs ++ [emit("jido.persist.hibernate.failed", %{reason: reason, persistence_key: opts[:persistence_key]})]}
        end
    end
  end

  # Default pass-through for every other signal.
  def on_signal(sig, ctx, _opts, next), do: next.(sig, ctx)

  defp emit(type, data), do: %Directive.Emit{signal: Signal.new!(type, data)}

  # Walk the agent module + its declared plugins; for each module that declares
  # @behaviour Jido.Persist.Transform, transform the corresponding slice value.
  defp apply_externalize(agent, agent_module), do: walk_transforms(agent, agent_module, :externalize)
  defp apply_reinstate(agent, agent_module),   do: walk_transforms(agent, agent_module, :reinstate)

  defp walk_transforms(agent, agent_module, callback) do
    mods = [agent_module | Enum.map(agent_module.plugins(), &unwrap_mod/1)]

    new_state =
      Enum.reduce(mods, agent.state, fn mod, acc ->
        if transform_impl?(mod) and Map.has_key?(acc, mod.path()) do
          Map.update!(acc, mod.path(), &apply(mod, callback, [&1]))
        else
          acc
        end
      end)

    %{agent | state: new_state}
  end

  defp unwrap_mod({mod, _opts}), do: mod
  defp unwrap_mod(mod) when is_atom(mod), do: mod

  defp transform_impl?(mod) do
    function_exported?(mod, :externalize, 1) and function_exported?(mod, :reinstate, 1)
  end
end
```

**No Slice, no state**. Persister doesn't appear anywhere on `agent.state`. Config lives in middleware `opts`, captured at chain-build time.

**Why middleware, not Slice + directive**: the Slice + directive approach (an interim proposal) ran IO *after* the chain unwinds, so any middleware observing `lifecycle.starting` saw pre-thaw `ctx.agent` in the same pass — an asymmetric in-chain view. The blocking-middleware approach is consistent: subsequent middleware (downstream of Persister in the chain) sees post-thaw `ctx.agent` in the same pass. Blocking IO on the mailbox path is the cost; lifecycle emissions are rare and one-shot.

**Retry middleware covers Persister IO failures** — as long as `Jido.Middleware.Retry` is positioned *outside* `Jido.Middleware.Persister` in the chain. A thaw IO failure propagates; Retry catches and re-invokes `next`. Chain ordering is user-declared; put Retry first if you want retry-on-thaw.

**Hibernate-on-terminate vs supervisor shutdown timeout**: `lifecycle.stopping` emits at the top of `terminate/2`, and the Persister middleware blocks synchronously on `Jido.Persist.hibernate/4`. If the IO exceeds the supervisor's shutdown timeout (default 5_000 ms on `child_spec`), the supervisor sends `:kill` mid-write — the checkpoint is partial/corrupt, no error surfaces. The contract is: **hibernate IO must finish within the configured shutdown timeout**. Two ways to satisfy it:
1. Use storage adapters with predictable, fast write paths (in-memory, local disk).
2. Bump the supervisor's shutdown timeout when configuring the agent's child_spec (e.g., `shutdown: 30_000` for slower remote storage).

The framework does not enforce its own hibernate timeout — that would just turn one corruption mode into another (timed-out write that the storage adapter still processes). The supervisor's timeout is the authoritative bound; users tune it for their workload. Document this in `guides/middleware.md` and the migration guide.

**Hibernate blocks the terminate path — shutdown_timeout must exceed hibernate duration.** The Persister middleware blocks synchronously on `Jido.Persist.hibernate/4` when `lifecycle.stopping` emits at the top of `terminate/2`. The framework's opinion: **hibernate should be fast**. If the user's storage is slow enough that hibernate can exceed the default GenServer shutdown timeout (5s under a Supervisor), the supervisor will `Process.exit(pid, :kill)` mid-write, producing a partial/corrupt checkpoint. Users with slow storage must increase the agent's `shutdown_timeout` in the supervisor's child_spec. This is a deliberate trade-off for the middleware-based architecture: IO on the mailbox path gives in-chain consistency at the cost of terminate-path latency.

### Custom persistence shape — `Jido.Persist.Transform` behaviour

Some slices need a different on-disk shape than in-memory (e.g., Thread writes entries to a journal and persists only a small pointer). Instead of a `transforms:` map in Persister opts, the slice module itself declares a behaviour:

```elixir
defmodule Jido.Persist.Transform do
  @moduledoc """
  Opt-in behaviour for Slice / Plugin modules that need custom serialization shape.

  Persister middleware walks every declared slice/plugin at hibernate and thaw.
  Modules that declare `@behaviour Jido.Persist.Transform` get `externalize/1`
  applied at hibernate time (to produce the serialized form) and `reinstate/1`
  at thaw time (to reconstruct the in-memory form).
  """

  @doc """
  Called on hibernate. Receives the current slice value at `agent.state[mod.path()]`.
  Returns the value to serialize — typically a small pointer or summary.
  Side effects (e.g., flushing a journal) run synchronously inside this function.
  """
  @callback externalize(slice_value :: term()) :: term()

  @doc """
  Called on thaw. Receives whatever `externalize/1` returned at the previous
  hibernate (rehydrated by the storage adapter's decoder). Returns the full
  slice value to place at `agent.state[mod.path()]`.
  """
  @callback reinstate(stored_value :: term()) :: term()
end
```

No `@optional_callbacks` — if you declare the behaviour you implement both. Slices that don't need transform just don't declare the behaviour; Persister's `function_exported?` check skips them.

**`Jido.Persist.thaw/3` and `hibernate/4` stay unchanged.** Transform is purely a Persister-middleware concern; the Persist module keeps its current signature. No `transforms:` option in Persister opts.

**`Jido.Thread.Persister` module goes away.** The externalize/reinstate live directly on `Jido.Thread.Plugin` (see its updated definition above in this task doc).

### `lib/jido/pod/bus_plugin.ex` → **Jido.Plugin**

Path: `:pod_bus`. Middleware half (trivially, it just relies on the Slice's static signal_routes, so the middleware half may be empty — in that case it's a pure Slice).

```elixir
defmodule Jido.Pod.BusPlugin do
  use Jido.Plugin,  # or Jido.Slice if no middleware needed
    name: "pod_bus",
    path: :pod_bus,
    actions: [AutoSubscribeChild, AutoUnsubscribeChild],
    signal_routes: [
      {"jido.agent.child.started", AutoSubscribeChild},
      {"jido.agent.child.exit", AutoUnsubscribeChild}
    ],
    schema: Zoi.object(%{
      bus: Zoi.atom(),
      subscriptions: Zoi.map() |> Zoi.default(%{})
    }),
    capabilities: [:bus_wiring]
end
```

The dynamic `signal_routes/1` function in today's [lines 77-86](../../lib/jido/pod/bus_plugin.ex) becomes the compile-time `signal_routes:` option. The `mount/2` logic at [lines 67-75](../../lib/jido/pod/bus_plugin.ex) (validating `:bus` atom) moves to a `Zoi.refine` on the schema.

## Files to modify

### `lib/jido/pod/runtime.ex`

- [line 23](../../lib/jido/pod/runtime.ex): `@pod_state_key Plugin.state_key_atom()` → `@pod_state_key Plugin.path()`. Since path is a compile-time atom (`:pod`), this is now constant; the helper function `state_key_atom/0` can be retired.
- [line 179](../../lib/jido/pod/runtime.ex): update any path references.

### `lib/jido/pod/mutable.ex`, `lib/jido/pod/topology_state.ex`, `lib/jido/pod/definition.ex`

- Every `@pod_state_key` reference ([mutable.ex:16,62-64,106-108](../../lib/jido/pod/mutable.ex); [topology_state.ex:13,24,31,41,49,102,117,153](../../lib/jido/pod/topology_state.ex); [definition.ex:9,75,85,95](../../lib/jido/pod/definition.ex)) continues to work since it's still pulling from `Jido.Pod.Plugin`, but the atom value changes from `:__pod__` to `:pod`.
- [lib/jido/pod/definition.ex:139-142](../../lib/jido/pod/definition.ex): validates that user-provided pod-replacement modules use `state_key :__pod__`. Update to check `.path() == :pod` instead.

### `lib/jido/agent/default_plugins.ex` — **flip to path-keyed** (C2 left it state_key-keyed)

Now that in-tree plugins expose `path/0` (via their new Slice-backed declarations), update `build_state_key_index/1` ([line 121-127](../../lib/jido/agent/default_plugins.ex)) to call `mod.path()` instead of `mod.state_key()`. Rename the helper to `build_path_index/1`.

Update the override map keys in every caller:
- Framework defaults constant ([line 51](../../lib/jido/agent/default_plugins.ex)) still lists the plugin modules — no change there; they just expose new `path/0`.
- Any internal test or doc example using `%{__thread__: false}` syntax → `%{thread: false}`.
- Moduledoc example on [lines 32, 38](../../lib/jido/agent/default_plugins.ex): update.

### `lib/jido/plugin/requirements.ex`

- Any `{:plugin, :something}` requirement references that used old state_key atoms — update to use new `path` atoms.

### `lib/mix/tasks/jido.gen.plugin.ex`

- [line 49, 53](../../lib/mix/tasks/jido.gen.plugin.ex) and the generator template at [lib/jido/igniter/templates.ex](../../lib/jido/igniter/templates.ex): emit `use Jido.Plugin, path: :name, ...` (not `state_key: :name, ...`) when scaffolding a new plugin. Remove any references to `mount/2`, `on_checkpoint/2`, `on_restore/2`, `handle_signal/2`, `transform_result/3` from the template.

## Files to create

### `lib/jido/persist/transform.ex`

The `Jido.Persist.Transform` behaviour module (callbacks `externalize/1` and `reinstate/1`). Slices declare `@behaviour Jido.Persist.Transform` when they need custom serialization shape. See the Persister middleware section above for the full definition.

**No separate `lib/jido/thread/persister.ex` module** — Thread's externalize/reinstate live directly on `Jido.Thread.Plugin` (see earlier in this task doc).

## Acceptance

- `mix compile --warnings-as-errors` passes
- Grepping `lib/` for `:__thread__`, `:__identity__`, `:__memory__`, `:__pod__`, `:__bus_wiring__` returns zero hits in source paths
- A scratch agent with `plugins: [Jido.Thread.Plugin, Jido.Identity.Plugin, Jido.Memory.Plugin]` starts; `agent.state == %{<declared_path>: ..., thread: nil, identity: nil, memory: nil}` (until ensure is called)
- `mix test` — **expect failures** in plugin test files that reference old state_key atoms; fixed in C8

## Out of scope

- Lifecycle signal emission from AgentServer (→ C6; the Pod plugin's middleware references `jido.agent.lifecycle.starting` now but the signal itself isn't emitted yet)
- Collapsing the two thaw paths (→ C6)
- Rewriting tests (→ C8)

## Risks

- The Pod plugin's `mount/2` logic (building initial topology state) is non-trivial — it uses `agent_module.topology/0` ([line 66-77](../../lib/jido/pod/plugin.ex)). Schema defaults can't call functions on the agent module; this initialization must happen elsewhere. Options:
  - (a) A `lifecycle.ready` action on the Pod slice that computes and writes topology via a `StateOp.SetPath` directive — elegant but creates a brief window where `agent.state.pod.topology` is nil.
  - (b) The Pod agent module itself seeds `agent.state.pod.topology` via its agent-level schema default. Requires the agent module to know the topology — which it already does.
  - **Recommended: (b).** Keep the Pod Plugin's schema minimal and let the declaring agent seed topology via its own schema default or initial state.
- The BusPlugin's `mount/2` validation on `:bus` atom moves to `Zoi.refine` in the config schema. Verify the error message is equivalent.
- Thread's externalize returns both a pointer AND side-effect directives (journal entries). The journal flush must complete before the Hibernate directive executor returns (inside `execute_directives/3` of the `lifecycle.stopping` chain pass) — or the caller's ack will fire before the journal is durably written. Confirm ordering during implementation; treat the flush as a synchronous sub-step of the Hibernate executor, not a returned directive that runs later.
- `Jido.Pod.BusPlugin.subscriptions` default (`%{}`) in the schema interacts with how the map is mutated by AutoSubscribeChild/AutoUnsubscribeChild via `StateOp`. Make sure the state-op path `[:pod_bus, :subscriptions]` matches what the actions write.
- External packages have no dependency on these specific plugin modules per ADR 0014 ("No external users exist"), so no deprecation shim is shipped. Verify this by searching this monorepo for `Jido.Thread.Plugin` etc. — confirm every caller is in-tree.
