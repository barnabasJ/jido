# Slices

A **Slice** is a declarative bundle of agent-state schema, actions, signal
routes, sensor subscriptions, and schedules. It is the pure-data tier of the
[Slice / Middleware / Plugin model](adr/0014-slice-middleware-plugin.md).

A Slice owns one flat atom in `agent.state` (its `path:`). Actions belonging
to that slice receive the slice value as their second argument and return a
new full slice value. Slices have no lifecycle callbacks — a Slice is fully
described by the keyword list passed to `use Jido.Slice`.

If you need to wrap signal processing (audit, retry, persist, transform),
that's the [Middleware](middleware.md) tier — not Slice. If you need both
in one module, use [`Jido.Plugin`](plugins.md) (a Slice + Middleware combo).

## Hello Slice

```elixir
defmodule MyApp.ChatSlice do
  use Jido.Slice,
    name: "chat",
    path: :chat,
    actions: [MyApp.Actions.SendMessage, MyApp.Actions.ListHistory],
    schema:
      Zoi.object(%{
        messages: Zoi.list(Zoi.any()) |> Zoi.default([]),
        model: Zoi.string() |> Zoi.default("gpt-4")
      }),
    signal_routes: [
      {"chat.send", MyApp.Actions.SendMessage},
      {"chat.history", MyApp.Actions.ListHistory}
    ]
end
```

That `use` block is the entire surface. There is no `mount/2`, no
`handle_signal/2`, no `transform_result/3` — those callbacks were retired in
[ADR 0014](adr/0014-slice-middleware-plugin.md).

## Configuration fields

| Field | Required | Purpose |
|---|---|---|
| `name` | yes | Human identifier; appears in logs and Discovery. Letters, digits, underscores. |
| `path` | yes | Atom key in `agent.state` where this slice lives. |
| `actions` | no (default `[]`) | Action modules contributed by this slice. Each action that touches this slice should declare matching `path:`. |
| `schema` | no | Zoi schema for the slice's state. Defaults from the schema seed `agent.state[path]` at `Agent.new/1`. |
| `config_schema` | no | Zoi schema for per-agent configuration (the second tuple element in `{Plugin, %{...}}`). |
| `signal_routes` | no | Static `signal_type → action` mappings. Compile-time only; no `signal_routes/1` callback. |
| `subscriptions` | no | Sensor subscription tuples like `{SensorModule, config}`. |
| `schedules` | no | Cron tuples like `{"*/5 * * * *", ActionModule}`. |
| `capabilities` | no | Atom list advertising what the slice provides (used by Discovery). |
| `requires` | no | Dependency tuples: `{:config, :token}`, `{:app, :req}`, `{:plugin, :http}`. |
| `description`, `category`, `vsn`, `tags`, `otp_app` | no | Metadata. |
| `singleton` | no (default `false`) | If `true`, the slice cannot be aliased via `as:` (raises at compile time). |

## Slice state and `agent.state[path]`

The agent struct's `state` is flat: each slice owns one key.

```elixir
agent.state == %{
  domain: %{...},      # the agent's own slice (declared on use Jido.Agent)
  chat: %{...},        # MyApp.ChatSlice
  thread: %{...},      # Jido.Thread.Plugin
  identity: %{...}     # Jido.Identity.Plugin
}
```

When the agent starts, each slice's state is seeded by:

1. `schema`'s defaults (Zoi `default/1` annotations);
2. then the per-agent config map merged in (`{MyApp.ChatSlice, %{model: "gpt-5"}}`);
3. then anything the caller passes as `state: %{chat: %{...}}` to `Agent.new/1`.

The merge is **shallow** — there is no deep-merge. An action returns the full
new slice value; partial-map returns are not interpreted (this changed in
ADR 0014; see [the migration guide](migration.md) for the recipe).

## Composing slices on an agent

Declare slices on an agent via the `plugins:` keyword. (`Jido.Plugin` is just
`use Jido.Slice` + `use Jido.Middleware`; for a Slice-only module, declare
the same way — slices and plugins share the keyword.)

```elixir
defmodule MyApp.Agent do
  use Jido.Agent,
    name: "my_agent",
    path: :app,
    schema: [counter: [type: :integer, default: 0]],
    plugins: [
      MyApp.ChatSlice,
      {MyApp.ChatSlice, as: :support, model: "gpt-4o"},
      Jido.Thread.Plugin
    ]
end
```

`as: :support` produces a derived path `:chat_support` and route prefix
`"support.chat"`. Two instances of the same Slice can run side-by-side as
long as the slice is not declared `singleton: true`.

Path collisions raise at compile time:

```text
** (CompileError) Duplicate slice paths: [:chat]
```

## Routing

Routes declared on a slice are **merged** with the agent's own routes and
prefixed by the slice's `route_prefix`:

| Source | Path on the wire |
|---|---|
| Agent: `signal_routes: [{"work.start", Foo}]` | `"work.start"` |
| Slice (`name: "chat"`): `signal_routes: [{"send", SendMessage}]` | `"chat.send"` |
| Slice instance (`as: :support`): same | `"support.chat.send"` |

The router is the unmodified [`Jido.Signal.Router`](signals.md). Priorities
follow the precedence agent (0) > slice (-10), so an agent's route wins on
collision.

## Schemas and validation

When a Slice declares a `schema:`, slice state is parsed through Zoi at
`Agent.new/1`. A failure raises `Jido.Agent.SliceValidationError` with the
offending path, the schema's error report, and the slice module — which
makes "I forgot a required field in plugin config" surface immediately at
boot, not in the middle of a signal. Schema-level `Zoi.transform/2` runs at
parse time, useful for runtime-derived fields:

```elixir
schema:
  Zoi.object(%{
    state: Zoi.string() |> Zoi.optional(),
    initial_state: Zoi.string() |> Zoi.default("idle"),
    transitions: Zoi.map(Zoi.string(), Zoi.list(Zoi.string())),
    terminal_states: Zoi.list(Zoi.string()) |> Zoi.default([])
  })
  |> Zoi.transform({__MODULE__, :seed_runtime_fields, []})
```

`seed_runtime_fields/2` then derives `state` from `initial_state` if the
caller didn't supply one. This pattern replaces the retired `mount/2`
callback for the "compute starting state from config" case.

## When to reach for Middleware instead

A Slice is the wrong tool when:

- you need to observe or transform every signal (audit, retry, persist, log),
- you need to gate a signal based on context (auth, rate-limit, tenant filter),
- you need to inject side effects around the action's return.

Those belong in [Middleware](middleware.md). Use `Jido.Plugin` if a single
module needs both — see [`Jido.Plugin.FSM`](../lib/jido/plugin/fsm.ex) for an
in-tree example (a Slice that supplies an FSM transition action and route).

## See also

- [ADR 0014 — Slice / Middleware / Plugin](adr/0014-slice-middleware-plugin.md) — design rationale
- [Middleware guide](middleware.md) — the wrap tier
- [Plugins guide](plugins.md) — the combo tier and migration recipes
- [Migration guide](migration.md) — pre-refactor → new shape
