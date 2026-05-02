# Plugins

A **Plugin** is `Jido.Slice` + `Jido.Middleware` in one module. Use it when
a single capability needs both:

- **State and routes** that other slices and the agent see (the Slice half), and
- **Pipeline behaviour** that wraps every signal — gate, transform, retry,
  persist, etc. (the Middleware half).

If you don't need the wrap, use [`Jido.Slice`](slices.md) directly. If you
don't need the data, use [`Jido.Middleware`](middleware.md) directly. Plugin
exists for the combo case — `Jido.Middleware.Persister` + the in-tree
combo plugins are the canonical examples.

## Hello Plugin

```elixir
defmodule MyApp.Audit.Plugin do
  use Jido.Plugin

  slice do
    name "audit"
    path :audit
    schema Zoi.object(%{
      events: Zoi.list(Zoi.any()) |> Zoi.default([])
    })
  end

  @impl Jido.Middleware
  def on_signal(signal, ctx, _opts, next) do
    record = %{type: signal.type, at: System.system_time(:millisecond)}
    new_events = ctx.agent.state.audit.events ++ [record]

    new_state = put_in(ctx.agent.state, [:audit, :events], new_events)
    ctx = %{ctx | agent: %{ctx.agent | state: new_state}}

    next.(signal, ctx)
  end
end
```

`use Jido.Plugin` exposes the slice DSL's sections plus
`@behaviour Jido.Middleware`, so the same module gets:

- a `:audit` slice on `agent.state` with schema-defaulted `events: []`, and
- a middleware callback that wraps every signal.

The middleware writes to the slice by staging `ctx.agent` and threading
the updated context to `next`. This is the documented exception to the
"directives mutate no state" rule: middleware may mutate `ctx.agent` for
I/O-staging purposes, and the staged value commits to `state.agent`
regardless of whether the downstream action errors.

If the audit data needed to flow back from an action instead — for
example, an action whose primary `path:` is `:orders` but that also
records to `:audit` in the same turn — that's the cross-slice case:
return `%Jido.Agent.SliceUpdate{slices: %{orders: ..., audit: ...}}`
from the action. See [Actions — Multi-slice returns](actions.md#multi-slice-returns).

## Configuration

The `slice do … end` section accepts the slice fields; the middleware
half is wired in by the `use Jido.Plugin` macro. Section reference:

| Section | Field | Notes |
|---|---|---|
| `slice` | `name` (required) | String name. |
| `slice` | `path` (required) | Slice key on `agent.state`. |
| `slice` | `schema`, `config_schema` | Zoi schemas. |
| `slice` | `description`, `category`, `vsn`, `otp_app`, `tags` | Metadata. |
| `signal_routes do route "type", Action end` | route entries | Compile-time routes. |
| `subscriptions do subscription Sensor, %{} end` | subscription entries | Sensor subs. |
| `schedules do schedule "cron", Action end` | schedule entries | Cron schedules. |
| `capabilities do capability :name end` | capability entries | Discovery. |
| `requires do requires :kind, :name end` | requires entries | Composition. |

Middleware does not take its own configuration in the DSL — the
per-instance `opts` map is what `{MyPlugin, %{...}}` produces when an
agent declares the plugin in `extensions: [...]`. Both halves see the
same map: the Slice as `config:`, the Middleware as the `opts` callback
arg.

## Routes, schedules, and subscriptions

Each is its own DSL section:

```elixir
defmodule MyApp.Cache.Plugin do
  use Jido.Plugin

  slice do
    name "cache"
    path :cache
    schema Zoi.object(%{entries: Zoi.map() |> Zoi.default(%{})})
  end

  signal_routes do
    route "cache.put", MyApp.Cache.Put
    route "cache.audit", MyApp.Cache.Audit, priority: 5
  end

  schedules do
    schedule "0 * * * *", MyApp.Cache.Compact
  end
end
```

The agent picks up these routes automatically when it lists the plugin
in `extensions: [...]`.

## Contributing a typed config block to the host agent

A plugin (or a bare slice) can opt into the *contribution mechanism* —
the host agent declares the plugin in `extensions: […]` and gets a
typed configuration block on the agent itself:

```elixir
defmodule MyApp.Cache.Plugin do
  use Jido.Plugin
  use Jido.Slice.Extension, host_section: :cache

  slice do
    name "cache"
    path :cache
    config_schema Zoi.object(%{ttl: Zoi.integer() |> Zoi.default(60)})
  end
end

defmodule MyApp.OrdersAgent do
  use Jido.Agent, extensions: [MyApp.Cache.Plugin]

  agent do
    name "orders"
    path :orders
    schema Zoi.object(%{...})
  end

  cache do
    ttl 300
    path :order_cache  # rename the slice mount path on this agent
  end
end
```

The contributed section's schema mirrors the slice's `config_schema/0`
plus a built-in `path:` field that lets the host rename where the slice
lives in `agent.state`. The slice's own runtime config validation runs
against the same shape, so `agent.state.order_cache.ttl == 300`
without any explicit wiring.

When to use the contribution mechanism vs. plain `extensions: [Mod]`:

- **Plain** — plugin has no per-host configuration, or its
  `config_schema/0` is empty. Just `extensions: [MyPlugin]` is enough.
- **Contribution** — plugin exposes a `config_schema/0` and the host
  needs to set fields. The typed block beats inline `{Mod, %{…}}`
  tuples because it gives compile-time validation and ExDoc-rendered
  docs.

## Where to look next

- [Slices guide](slices.md) — the pure data tier
- [Middleware guide](middleware.md) — the wrap tier
- [Migration guide — keyword form to Spark DSL](migration-spark-dsl.md) —
  conversion recipes for older code
- [`Jido.Slices.Thread`](../lib/jido/thread/slice.ex) — in-tree slice example
- [`Jido.Middleware.Persister`](../lib/jido/middleware/persister.ex) — in-tree middleware example
