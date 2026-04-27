# Middleware

A **Middleware** wraps the agent's signal pipeline. It is a single-tier,
`next`-passing chain: each middleware sits between AgentServer and the
inner pipeline (routing → action → directives), and decides whether to pass
through, transform, retry, swallow, or short-circuit.

This is the cross-cutting tier in the [Slice / Middleware / Plugin
model](adr/0014-slice-middleware-plugin.md). Where a Slice is "what the
agent does," Middleware is "what happens around each signal."

## The contract

```elixir
@callback on_signal(
            signal :: Jido.Signal.t(),
            ctx :: map(),
            opts :: map(),
            next :: (Jido.Signal.t(), map() -> {map(), [struct()]})
          ) :: {map(), [struct()]}
```

Four arguments, one return shape. The chain builder closes over each
middleware's per-registration `opts` at construction time, so the callback
receives the same map every invocation.

| Arg | Meaning |
|---|---|
| `signal` | The triggering `%Jido.Signal{}`. |
| `ctx` | Per-signal runtime context: `current_user`, `trace_id`, agent identity (`agent_module`, `partition`, `parent`, etc.). Lives on `signal.extensions[:jido_ctx]` on the wire; promoted to an explicit arg here. |
| `opts` | Per-registration options. Bare module registration → `%{}`. `{Module, %{...}}` registration → that map. |
| `next` | The continuation. Calling `next.(signal, ctx)` invokes the rest of the chain. |

The return is `{new_ctx, [directive]}` — a possibly-modified context and the
directive list the chain produces. Middleware can:

- **Pass through**: `next.(signal, ctx)`.
- **Mutate ctx before `next`**: thread a value down to inner middleware / actions.
- **Mutate ctx or directives after `next`**: read or rewrite the result.
- **Retry**: call `next` more than once.
- **Swallow / short-circuit**: skip `next` and return `{ctx, []}`.

## Hello Middleware

```elixir
defmodule MyApp.Audit do
  use Jido.Middleware

  @impl true
  def on_signal(signal, ctx, _opts, next) do
    started = System.monotonic_time()
    {new_ctx, dirs} = next.(signal, ctx)
    elapsed = System.monotonic_time() - started

    :telemetry.execute(
      [:my_app, :audit, :stop],
      %{us: System.convert_time_unit(elapsed, :native, :microsecond)},
      %{type: signal.type}
    )

    {new_ctx, dirs}
  end
end
```

Register it on an agent:

```elixir
defmodule MyApp.Agent do
  use Jido.Agent,
    name: "my_agent",
    path: :app,
    middleware: [
      MyApp.Audit,
      {Jido.Middleware.Retry, %{max_attempts: 3, pattern: "work.**"}}
    ]
end
```

The chain composes outside-in. The first middleware listed wraps everything
after it. So `[Audit, Retry]` means `Audit(Retry(action))` — `Audit` sees
the *final* return after retries finished.

## Common patterns

### Gate

```elixir
def on_signal(signal, ctx, _opts, next) do
  if authorized?(ctx[:current_user], signal.type) do
    next.(signal, ctx)
  else
    {ctx, [%Directive.Error{reason: :unauthorized}]}
  end
end
```

### Transform (request)

```elixir
def on_signal(%{type: "submit"} = sig, ctx, _opts, next) do
  next.(%{sig | data: normalize(sig.data)}, ctx)
end

def on_signal(sig, ctx, _opts, next), do: next.(sig, ctx)
```

### Transform (response)

```elixir
def on_signal(signal, ctx, _opts, next) do
  {ctx, dirs} = next.(signal, ctx)
  {ctx, Enum.map(dirs, &maybe_redact/1)}
end
```

### Persist

`Jido.Middleware.Persister` runs hibernate/thaw IO synchronously around
`jido.agent.lifecycle.starting` / `stopping` signals. It mutates `ctx.agent`
in place after thaw, so the rest of the pipeline sees the rehydrated
struct. See [the source](../lib/jido/middleware/persister.ex).

### Retry

[`Jido.Middleware.Retry`](../lib/jido/middleware/retry.ex) re-invokes `next`
when the chain returns `%Directive.Error{}`. Configurable max attempts
and an optional `Jido.Signal.Router` pattern to scope which signals retry.

```elixir
middleware: [
  {Jido.Middleware.Retry, %{max_attempts: 5, pattern: "work.**"}}
]
```

Retry's only internal state is a counter on the stack — there's no
shared mutable state, so it composes cleanly with any other middleware.

### Log-and-convert errors

```elixir
def on_signal(signal, ctx, _opts, next) do
  {ctx, dirs} = next.(signal, ctx)

  Enum.each(dirs, fn
    %Directive.Error{reason: r} ->
      Logger.error("agent #{ctx[:agent_id]} failed #{signal.type}: #{inspect(r)}")
    _ -> :ok
  end)

  {ctx, dirs}
end
```

## Stateless middleware vs. Plugin-paired state

Middleware does not own any agent state. It runs as code inside the
AgentServer process, with whatever capture closures hold. To carry state
across signals (rate-limit counters, circuit-breaker open/closed, user
session caches), either:

- **Process-local**: `Process.put/get` inside the AgentServer process (simple, OTP-friendly).
- **External store**: `:ets`, `:persistent_term`, or a downstream service.
- **Plugin pairing**: declare a Slice next to the Middleware so the data
  lives in `agent.state[plugin.path]`. The middleware reads via
  `ctx.agent.state[path]` and stages writes by passing an updated `ctx`
  to `next` — for example,
  `next.(signal, %{ctx | agent: %{ctx.agent | state: new_state}})`.
  This is the documented `ctx.agent`-staging exception to "directives
  mutate no state" per [ADR 0018](adr/0018-tagged-tuple-return-shape.md) §1
  and [ADR 0019](adr/0019-actions-mutate-state-directives-do-side-effects.md) §1.
  See [`Jido.Middleware.Persister`](../lib/jido/middleware/persister.ex)
  for the canonical example (it stages a thawed agent on
  `jido.agent.lifecycle.starting`).

The Plugin route is the right call when the state is *part of the agent's
identity* (must persist through hibernate, must be visible to other
actions). Middleware-without-state is the right call for ephemeral
counters and observability.

## Interaction with `cast_and_await` and `subscribe`

Both [`AgentServer.cast_and_await/4`](../lib/jido/agent_server.ex) and
[`subscribe/4`](../lib/jido/agent_server.ex) fire selectors **after the
outermost middleware unwinds**, not on every retry. So:

- Retry middleware re-invoking `next` 3× still produces exactly **one**
  ack per `cast_and_await`.
- Middleware that swallows a signal (skips `next`) still produces one
  ack — using whatever `agent.state` looks like at the moment of
  swallowing.

If a middleware mutates `ctx.agent` (like `Persister` does on thaw), the
selector sees the updated agent. This is what makes `cast_and_await` work
across the full pipeline: the selector reads the *post-pipeline* state.

## Order matters

Middleware composes outside-in. Concretely:

```elixir
middleware: [Retry, Persister, Audit]
```

is `Retry(Persister(Audit(action)))`. Retry sees the *final* result of
everything inside it. If the Persister middleware raises during a thaw IO
failure, Retry catches it and re-invokes `next`. If you reorder to
`[Persister, Retry, Audit]`, Retry can't catch a Persister thaw failure
because Persister wraps it.

A reasonable default order, outermost first:

1. `Retry` — wrap everything that's transient
2. Auth / rate-limit gates
3. `Persister` — IO around lifecycle
4. Audit / log / observability — closest to the action so timings reflect actual work

## See also

- [ADR 0014 — Slice / Middleware / Plugin](adr/0014-slice-middleware-plugin.md) — design rationale and decision log
- [`Jido.Middleware.Persister`](../lib/jido/middleware/persister.ex) — reference implementation (hibernate / thaw)
- [`Jido.Middleware.Retry`](../lib/jido/middleware/retry.ex) — reference implementation (retry on `%Error{}`)
- [Slices guide](slices.md) — the data tier
- [Plugins guide](plugins.md) — when you need both
- [Migration guide](migration.md) — pre-refactor → new shape
