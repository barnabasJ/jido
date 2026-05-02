# Slices

A **Slice** is a declarative bundle of agent-state schema, signal
routes, sensor subscriptions, and schedules. It is the pure-data tier
of the Slice / Middleware / Plugin model.

A Slice owns one flat atom in `agent.state` (its `path:`). Actions
belonging to that slice receive the slice value as their second argument
and return a new full slice value. A Slice is fully described by the
sectioned DSL its module declares — there are no lifecycle callbacks.

If you need to wrap signal processing (audit, retry, persist, transform),
that's the [Middleware](middleware.md) tier — not Slice. If you need both
in one module, use [`Jido.Plugin`](plugins.md) (a Slice + Middleware combo).

## Hello Slice

```elixir
defmodule MyApp.ChatSlice do
  use Jido.Slice

  slice do
    name "chat"
    path :chat
    schema Zoi.object(%{
      messages: Zoi.list(Zoi.any()) |> Zoi.default([]),
      model: Zoi.string() |> Zoi.default("gpt-4")
    })
  end

  signal_routes do
    route "chat.send", MyApp.Actions.SendMessage
    route "chat.history", MyApp.Actions.ListHistory
  end
end
```

That's the entire surface. The slice contributes its `signal_routes`,
`schedules`, `subscriptions`, `capabilities`, and `requires` sections to
any agent that lists it in `extensions: […]`.

## DSL sections

| Section | Required | Purpose |
|---|---|---|
| `slice` | yes | Identity and base configuration. See fields below. |
| `signal_routes` | yes | At least one `route "type", Action` entry. |
| `subscriptions` | no | `subscription Sensor, %{config}` entries. |
| `schedules` | no | `schedule "cron", Action` entries. |
| `capabilities` | no | `capability :name` entries (used by Discovery). |
| `requires` | no | `requires :kind, :name` dependencies — kinds are `:config`, `:app`, `:plugin`, `:slice`. |

### `slice do … end` fields

| Field | Required | Purpose |
|---|---|---|
| `name` | yes | Human identifier; appears in logs and Discovery. Letters, digits, underscores. |
| `path` | yes | Atom key in `agent.state` where this slice lives. |
| `schema` | yes (with at least one route) | Zoi schema for the slice's state. Defaults seed `agent.state[path]` at `Jido.Agent.new/1`. |
| `config_schema` | no | Zoi schema for per-agent configuration (the second tuple element in `{Slice, %{...}}`). |
| `description`, `category`, `vsn`, `tags`, `otp_app` | no | Metadata. |

## Slice state and `agent.state[path]`

The agent struct's `state` is flat: each slice owns one key.

```elixir
agent.state == %{
  domain: %{...},      # the agent's own slice (declared on use Jido.Agent)
  chat: %{...},        # MyApp.ChatSlice
  thread: %{...},      # Jido.Slices.Thread
  identity: %{...}     # Jido.Slices.Identity
}
```

When the agent starts, each slice's state is seeded by:

1. `schema`'s defaults (Zoi `default/1` annotations);
2. then the per-agent config map merged in (`{MyApp.ChatSlice, %{model: "gpt-5"}}`);
3. then anything the caller passes as `state: %{chat: %{...}}` to `Jido.Agent.new/1`.

The merge is **shallow** — there is no deep-merge. An action returns the
full new slice value; partial-map returns are not interpreted.

## Composing slices on an agent

Declare slices on an agent via the `extensions: […]` keyword. The
compile-time walker classifies each entry by its DSL — slice modules
contribute their `signal_routes`, `schedules`, etc. to the host. Plugins
(`use Jido.Plugin` = Slice + Middleware) and bare middleware go in the
same `extensions: …` list.

```elixir
defmodule MyApp.Agent do
  use Jido.Agent,
    extensions: [
      MyApp.ChatSlice,
      Jido.Slices.Thread
    ]

  agent do
    name "my_agent"
    path :app
    schema [counter: [type: :integer, default: 0]]
  end
end
```

Path collisions raise at compile time:

```text
** (Spark.Error.DslError) Duplicate slice paths: [:chat]
```

## Routing

Routes declared on a slice merge with the agent's own routes. The
router is the unmodified [`Jido.Signal.Router`](signals.md). Priorities
follow the precedence agent (0) > slice (-10), so an agent's route wins on
collision.

## Schemas and validation

When a Slice declares a `schema:`, slice state is parsed through Zoi at
`Jido.Agent.new/1`. A failure raises `Jido.Agent.SliceValidationError` with the
offending path, the schema's error report, and the slice module — which
makes "I forgot a required field in slice config" surface immediately at
boot, not in the middle of a signal. Schema-level `Zoi.transform/2` runs at
parse time, useful for runtime-derived fields:

```elixir
slice do
  name "fsm"
  path :fsm
  schema Zoi.object(%{
    state: Zoi.string() |> Zoi.optional(),
    initial_state: Zoi.string() |> Zoi.default("idle"),
    transitions: Zoi.map(Zoi.string(), Zoi.list(Zoi.string())),
    terminal_states: Zoi.list(Zoi.string()) |> Zoi.default([])
  })
  |> Zoi.transform({__MODULE__, :seed_runtime_fields, []})
end
```

`seed_runtime_fields/2` then derives `state` from `initial_state` if the
caller didn't supply one — useful when the starting slice value depends
on the config.

## When to reach for Middleware instead

A Slice is the wrong tool when:

- you need to observe or transform every signal (audit, retry, persist, log),
- you need to gate a signal based on context (auth, rate-limit, tenant filter),
- you need to inject side effects around the action's return.

Those belong in [Middleware](middleware.md). Use `Jido.Plugin` if a single
module needs both. The `Jido.Plugins.FSM` module is the in-tree slice
example (a slice that supplies FSM transition action and route).

## See also

- [Middleware guide](middleware.md) — the wrap tier
- [Plugins guide](plugins.md) — the combo tier
- [Migration: keyword form to Spark DSL](migration-spark-dsl.md) — recipes for older code
