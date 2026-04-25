# Plugins

A **Plugin** is `Jido.Slice` + `Jido.Middleware` in one module. Use it when
a single capability needs both:

- **State and routes** that other slices and the agent see (the Slice half), and
- **Pipeline behaviour** that wraps every signal — gate, transform, retry,
  persist, etc. (the Middleware half).

If you don't need the wrap, use [`Jido.Slice`](slices.md) directly. If you
don't need the data, use [`Jido.Middleware`](middleware.md) directly. Plugin
exists for the combo case — `Jido.Plugin.FSM` and `Jido.Middleware.Persister`
are the in-tree examples.

## Hello Plugin

```elixir
defmodule MyApp.Audit.Plugin do
  use Jido.Plugin,
    name: "audit",
    path: :audit,
    schema:
      Zoi.object(%{
        events: Zoi.list(Zoi.any()) |> Zoi.default([])
      })

  alias Jido.Agent.{Directive, StateOp}

  @impl Jido.Middleware
  def on_signal(signal, ctx, _opts, next) do
    {new_ctx, dirs} = next.(signal, ctx)

    record = %{type: signal.type, at: System.system_time(:millisecond)}
    events = ctx.agent.state.audit.events ++ [record]

    {new_ctx, dirs ++ [%StateOp.SetPath{path: [:audit, :events], value: events}]}
  end
end
```

`use Jido.Plugin` expands to `use Jido.Slice` + `use Jido.Middleware`, so
the same module gets:

- a `:audit` slice on `agent.state` with schema-defaulted `events: []`, and
- a middleware callback that wraps every signal.

The `agent.state.audit.events` write goes through the normal directive
pipeline — no privileged access, just the same `%StateOp.SetPath{}` an
action would emit.

## Configuration

`use Jido.Plugin` accepts the union of Slice and Middleware options. The
full list:

| Field | Tier | Notes |
|---|---|---|
| `name`, `path` | Slice | Required. |
| `actions`, `schema`, `config_schema` | Slice | See [Slices](slices.md). |
| `signal_routes`, `subscriptions`, `schedules` | Slice | Compile-time, prefixed by route_prefix. |
| `capabilities`, `requires`, `singleton` | Slice | Discovery + composition. |
| `description`, `category`, `vsn`, `tags`, `otp_app` | Slice | Metadata. |

Middleware does not take its own configuration in the `use` block — the
per-instance `opts` map is what `{MyPlugin, %{...}}` produces when an agent
declares the plugin. Both halves see the same map: the Slice as `config:`,
the Middleware as the `opts` callback arg.

## When to choose which

```text
        Need to wrap signals?
               |
       +-------+--------+
       |                |
       no              yes
       |                |
       v                v
    Slice         Need slice state?
                       |
              +--------+--------+
              |                 |
              no               yes
              |                 |
              v                 v
         Middleware           Plugin
```

Concrete examples:

- `Jido.Thread.Plugin` — chat history. Slice (state). The Plugin macro is
  used because the persistence transform `to_persistable/1` /
  `from_persistable/1` lives in the same module; it has no `on_signal`
  hook, so it's effectively Slice-only.
- `Jido.Middleware.Persister` — hibernate/thaw. Middleware (no slice).
- `Jido.Plugin.FSM` — finite-state machine. Slice. (Despite the
  "Plugin" name, this one is `use Jido.Slice` because there's no
  middleware half.)
- A Plugin (real combo): an audit plugin that records every signal in its
  own slice — both `path:` *and* `on_signal/4`.

## Migration recipes (pre-0014 → new shape)

The old plugin surface had four behavioural callbacks:
`mount/2`, `handle_signal/2`, `transform_result/3`, `on_checkpoint/2`.
All four are retired. Here's what to do with each.

### `state_key:` → `path:`

Mechanical. Same atom, different name.

```elixir
# Before
use Jido.Plugin, name: "x", state_key: :x_data, actions: [...]

# After
use Jido.Plugin, name: "x", path: :x_data, actions: [...]
```

### `mount/2` — four replacement patterns

The retired `mount/2` callback initialized slice state when the agent
started. ADR 0014 splits this case into four patterns; pick whichever
applies:

#### 1. Nothing (the slice is "just data")

If `mount/2` returned `{:ok, nil}` or `{:ok, %{}}`, just delete the
callback. Schema defaults seed the slice automatically.

```elixir
# Before
use Jido.Plugin, name: "x", state_key: :x, ...

@impl Jido.Plugin
def mount(_agent, _config), do: {:ok, %{}}

# After — just remove mount/2
use Jido.Plugin, name: "x", path: :x, ...
```

#### 2. Echo per-agent config into the slice

If `mount/2` copied the config map into slice state, you don't need the
callback. `Agent.new/1` automatically merges `{Plugin, %{...}}` config on
top of schema defaults.

```elixir
# Before
def mount(_agent, config), do: {:ok, config}

# After — declare config_schema and use it as the slice schema, or merge them.
use Jido.Plugin,
  name: "x",
  path: :x,
  schema: Zoi.object(%{token: Zoi.string()})

# Then the agent declares: plugins: [{MyPlugin, %{token: "abc"}}]
# and agent.state.x.token == "abc" automatically.
```

#### 3. Compile-time derivation from the agent module

If `mount/2` derived state from the agent module itself (e.g. `Jido.Pod`
seeding the topology from `agent_module.topology()`), do that derivation
in a wrapper macro that overrides `Agent.new/1` to inject `state:` before
delegating. See [`Jido.Pod`](../lib/jido/pod.ex) for the in-tree example.

#### 4. Runtime-derived (rare)

If `mount/2` needed agent-instance data not available at config time,
declare an action routed on `jido.agent.lifecycle.starting` that computes
the value and writes it via a `%StateOp.SetPath{}` directive. The
lifecycle signal fires inside `AgentServer.init/1`, before any user
signal — see [ADR 0015](adr/0015-agent-start-is-signal-driven.md).

### `handle_signal/2` → `on_signal/4` (Middleware)

```elixir
# Before
def handle_signal(signal, context) do
  Logger.info("got #{signal.type}")
  {:ok, signal}
end

# After (Middleware tier; the Plugin macro provides on_signal/4 by
# inheriting use Jido.Middleware)
@impl Jido.Middleware
def on_signal(signal, ctx, _opts, next) do
  Logger.info("got #{signal.type}")
  next.(signal, ctx)
end
```

### `transform_result/3` → `on_signal/4` after `next`

```elixir
# Before
def transform_result(_action, {:ok, result}, _context) do
  {:ok, Map.put(result, :transformed, true)}
end

# After — wrap the directives that come back from next
@impl Jido.Middleware
def on_signal(signal, ctx, _opts, next) do
  {ctx, dirs} = next.(signal, ctx)
  {ctx, Enum.map(dirs, &transform/1)}
end
```

### `on_checkpoint/2` / `on_restore/2` → Persister middleware MFA

The `Jido.Persist.Transform` behaviour is the new home for shape-shifting
slices for storage. Implement `externalize/1` and `reinstate/1` on the
Plugin module; the Persister middleware walks every declared plugin and
applies the transform pair around hibernate/thaw automatically.

```elixir
defmodule MyApp.Cache.Plugin do
  use Jido.Plugin, name: "cache", path: :cache, schema: ...

  @behaviour Jido.Persist.Transform

  @impl Jido.Persist.Transform
  def externalize(slice), do: %{key: slice.key}  # drop the heavy cached values

  @impl Jido.Persist.Transform
  def reinstate(stub), do: Map.put(stub, :values, %{})
end
```

See [ADR 0015](adr/0015-agent-start-is-signal-driven.md) for the full
hibernate/thaw model.

### `signal_routes/1` → static `signal_routes:`

Dynamic, runtime-evaluated `signal_routes/1` callbacks are retired.
Routes are declared once at compile time:

```elixir
use Jido.Plugin,
  name: "x",
  path: :x,
  signal_routes: [
    {"x.do", MyAction},
    {"x.audit", AuditAction, priority: 5}
  ]
```

If you really need conditional routing, branch inside the action — the
router gets you to the action; the action decides what to do.

## Where to look next

- [ADR 0014 — Slice / Middleware / Plugin](adr/0014-slice-middleware-plugin.md) — design rationale
- [Slices guide](slices.md) — the pure data tier
- [Middleware guide](middleware.md) — the wrap tier
- [Migration guide](migration.md) — full pre-0014 → new shape recipes
- [`Jido.Thread.Plugin`](../lib/jido/thread/plugin.ex) — in-tree slice example
- [`Jido.Middleware.Persister`](../lib/jido/middleware/persister.ex) — in-tree middleware example
- [`Jido.Plugin.FSM`](../lib/jido/plugin/fsm.ex) — in-tree slice that's named "Plugin" for legacy reasons
