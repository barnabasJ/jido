# 0012. Middleware for cross-cutting concerns

- Status: Superseded by [0013](0013-slices-middleware-plugins.md)
- Implementation: Pending
- Date: 2026-04-22
- Related commits: —
- Companion ADR: [0011](0011-retire-strategy-plugins-are-control-flow.md) (retires Strategy, moves control flow into plugins)
- Superseded-by: [0013](0013-slices-middleware-plugins.md) — the middleware design stands as specified here; [0013](0013-slices-middleware-plugins.md) folds it into a three-tier vocabulary (slice/middleware/plugin), replaces the `state_key: :__x__` convention with flat-atom `path:` registration, and moves runtime identity (`partition`/`parent`/`orphaned_from`) to `%AgentServer.State{}` so `agent.state` is purely slice-owned.

## Context

With core `cmd/2` Elm-shaped after [ADR 0009](0009-inline-signal-processing.md) and plugins acting as pure slices after [ADR 0011](0011-retire-strategy-plugins-are-control-flow.md), cross-cutting concerns (logging, persistence, retry, auth, rate-limiting, telemetry) have no unified home. Today they are scattered across four separate mechanisms, each partial:

| Concern | Current home | Problem |
|---|---|---|
| Signal-layer gating, transform, abort | Plugin `handle_signal/2` | Mixes capability with policy; no composition; plugin authors who want ratelimiting must co-locate unrelated logic |
| Cmd-result post-processing | Plugin `transform_result/3` | Same problem; only one plugin can reasonably wrap a given cmd |
| Retry / stop-on-error / drop-on-error | `AgentServer.error_policy` config | One-of-N enum; no composition; can't layer "log + retry + stop" |
| Pre/post-execution hooks | Agent `on_before_cmd/2` / `on_after_cmd/3` | Exactly two fixed slots; no retry, no branching on result, no ordering across agents |

Four mechanisms, none composing with the others. Meanwhile, the Jido core is now structurally identical to Redux (signals ≡ actions, directives ≡ effects, plugins ≡ slices, `cmd/2` ≡ dispatch→reducer). Redux solves exactly this problem with **middleware chains** — a uniform `next`-passing contract where each layer wraps execution with an orthogonal concern, and the chain is composed at configuration time. It is a known-working shape.

Middleware is a strict superset for composability: engine-shaped things (FSM, ReAct) compose *inside* a single middleware (redux-saga does this); the reverse — composing middleware inside an engine — reinvents the middleware contract. Since control flow has moved to plugins per 0011, the layer that needs composition is the cross-cutting layer.

## Decision

Introduce `Jido.Middleware` as the unified extension point for cross-cutting concerns. Two optional callbacks, one chain per agent, composed at compile time. Redux-style semantics throughout.

### Behaviour

```elixir
defmodule Jido.Middleware do
  @callback on_signal(signal :: Signal.t(), ctx :: map(), next :: (Signal.t(), map() -> {map(), [Directive.t()]})) ::
              {map(), [Directive.t()]}

  @callback on_cmd(agent :: Agent.t(), instructions :: [Instruction.t()], ctx :: map(),
                   next :: (Agent.t(), [Instruction.t()], map() -> {Agent.t(), [Directive.t()]})) ::
              {Agent.t(), [Directive.t()]}

  @optional_callbacks on_signal: 3, on_cmd: 4
end
```

Middleware declares one or both callbacks. `on_signal` runs before routing; `on_cmd` runs around `cmd/2`. Return shape mirrors Redux: call `next` to pass through (optionally transforming inputs or wrapping outputs); don't call `next` to swallow. No `{:abort, reason}` tuple — to notify upstream of a rejection, emit an `%Error{}` or custom directive.

### Agent declaration

```elixir
defmodule MyAgent do
  use Jido.Agent,
    name: "my_agent",
    plugins:    [ChatPlugin, ReactPlugin],
    middleware: [Logger, Retry, LogErrors, Persister]
end
```

The `middleware:` list is compiled into a single chain at agent compile time. Each middleware wraps the next in the list; the last wraps the core pipeline (routing + `cmd/2` + directive execution).

### Pipeline

```
signal arrives
  → middleware on_signal chain  (gate / transform / swallow)
  → routing (plugin/agent signal_routes)
  → middleware on_cmd chain     (wrap / retry / persist / log)
    → core cmd/2: action → slice update + directives
  → directives execute inline (0009)
```

### Absorptions

Four existing mechanisms collapse into middleware:

1. **Plugin `handle_signal/2` → middleware `on_signal`.** The "intercept this signal before routing" case is what `on_signal` is for. Plugins shed the callback.
2. **Plugin `transform_result/3` → middleware `on_cmd` after-`next`.** The "wrap the cmd result" case is what `on_cmd` is for after calling `next`. Plugins shed the callback.
3. **`AgentServer.error_policy` config → composable error middlewares.** Ship `Jido.Middleware.Retry`, `Jido.Middleware.CircuitBreaker`, `Jido.Middleware.LogErrors`, `Jido.Middleware.StopOnError`. Users compose them. The single-enum `:stop_on_error | :drop | :retry` config and its state field retire.
4. **Agent hooks `on_before_cmd/2` / `on_after_cmd/3` → middleware `on_cmd` before/after `next`.** The two fixed slots retire; anything they did lands in middleware with full ordering control.

### Standard library

Ship under `lib/jido/middleware/`:

- `Logger` — `on_signal` + `on_cmd` wrap; structured logs around both tiers.
- `Retry` — `on_cmd` wraps `next` with bounded retry.
- `CircuitBreaker` — `on_cmd` bails after N consecutive failures; owns an optional slice `:__circuit_breaker__` for state.
- `LogErrors` — `on_cmd` after-`next`; logs failures and emits `%Error{}` directive.
- `StopOnError` — `on_cmd` after-`next`; emits `%Stop{}` directive on failure.
- `Persister` — `on_cmd` after-`next`; spawns a task that writes agent state to storage (uses the spawn-task-emit-signal pattern from 0009).

Default middleware chain for agents that declare none reproduces today's default `error_policy` semantics: `[LogErrors]`.

### Middleware state

Stateless by default. When a middleware needs persistent state, it owns its own namespaced slice key — the same pattern plugins use. Example: `Jido.Middleware.CircuitBreaker` reads/writes `agent.state[:__circuit_breaker__]`. No dedicated `:__middleware__` umbrella key; collisions between middlewares (or with plugins) are user error, same as plugin slice collisions today.

### Timeouts: directive-shaped vs. middleware-shaped

Timeout concerns split cleanly along an existing seam and need no new framework primitive.

- **Per-step / per-task timeouts are a property of the task-spawning directive.** The vocabulary already supports this via user-defined directives ([guides/directives.md](../directives.md) — "The runtime dispatches on struct type — no core changes needed"). Pattern:

  ```elixir
  %Jido.Agent.Directive.SpawnTask{
    task: fn -> call_tool(name, args) end,
    timeout: 5_000,
    on_success: "tool.result",
    on_timeout: "tool.timeout",
    tag: "call_abc123"
  }
  ```

  The directive executor spawns a supervised task with a deadline. On completion it emits `on_success` with the result; on deadline it kills the task and emits `on_timeout`. Both outcomes flow back through `signal_routes` (per [ADR 0009](0009-inline-signal-processing.md)). The timer is colocated with the work that uses it, and both outcomes are expressed in the signal vocabulary — no middleware state, no framework-level scheduler.

- **Cumulative and idle timeouts are middleware.** A loop with a 30-second budget tracks elapsed time on `on_cmd` entry and emits `%Stop{}` when exceeded. An idle timeout ("no progress in N seconds") uses a self-scheduled timer signal that checks progress state on wake-up. Both are ordinary middleware composition — no new hook shape needed.

The vocabulary stays small: new timeout needs become either new directives (when the deadline bounds a specific piece of work) or new middleware (when the deadline bounds a session or a trajectory). Neither requires a framework-level "timeout primitive."

## Consequences

- **Plugins become pure Redux slices.** Combined with ADR 0011, the plugin surface shrinks to `state_key`, `schema`, `actions`, `signal_routes` (plus the 0007 lifecycle callbacks `after_start/1`, `to_persistable/1`, `from_persistable/1` for persistence-related concerns). No intercept callbacks. The "plugins are slices, middleware is middleware" factoring mirrors Redux point-for-point.

- **Cross-cutting composition becomes a first-class concept.** Ordering is user-declared per agent. `[Logger, Auth, Retry, Persister]` and `[Auth, Logger, Retry, Persister]` produce different behaviour, and the difference is visible at the agent declaration site. No framework-enforced priorities (unlike the current signal-router's priority 50/0/-10 tiers, which this ADR leaves untouched for plugin/agent/builtin routing).

- **Error policy moves from config to code.** Users pick and compose from the standard error middlewares. The `error_policy` option on `Jido.AgentServer.Options` retires, along with any state tracking around retry counts that currently lives in `%AgentServer.State{}`.

- **Breaking change for plugin authors using `handle_signal/2` or `transform_result/3`.** Migration is mechanical: the `handle_signal/2` body moves into an `on_signal/3` middleware; the `transform_result/3` body moves into `on_cmd/4`'s after-`next` section. In-repo callers are migrated with the ADR.

- **Breaking change for agents using `on_before_cmd/2` / `on_after_cmd/3`.** Mechanical migration to middleware. These hooks were thinly used in-repo; the retirement cleans them up without loss.

- **`on_signal` cannot reinject new signals into the mailbox**; middleware wanting to trigger new work emits a `%Directive.Emit{}`. The `next` contract is "this signal, possibly transformed" — not "a signal of your choosing." Reinjection primitive is a deliberate non-feature to keep the chain ordering interpretable.

- **Middleware cannot see `%AgentServer.State{}`.** It operates on `%Agent{}` and `%Signal{}`. Server-state access continues to live in directives ([ADR 0003](0003-server-state-access-lives-in-directives.md)) — middleware does not erode that boundary.

- **`guides/strategies.md` / `guides/custom-strategies.md` retire** (per 0011). `guides/plugins.md` updates to reflect the pure-slice shape. New `guides/middleware.md` covers the contract, standard library, and migration recipes from the four absorbed mechanisms.

## Alternatives considered

- **Leave each of the four mechanisms in place.** Maintains the status quo at the cost of teaching every new contributor four separate extension points. No composition story ever lands. Error policy stays a fixed enum. Rejected: four half-answers to one question.

- **Expand agent hooks to more than before/after slots.** Adds `on_error/3`, `on_retry/3`, etc. Addresses specific pain points but still lacks user-level composition — the slots are framework-defined, not stackable. Rejected: ad-hoc extension that doesn't compose.

- **Move all cross-cutting into plugins via additional plugin callbacks.** Violates the "plugins are pure slices" line the 0011/0012 pair is drawing. Plugins would recover every intercept concern they're currently shedding, just with a different name. Rejected: reintroduces the exact conflation 0011 exists to remove.

- **Single-tier middleware (`on_cmd` only).** Simpler contract; the signal-layer concerns (auth gating, signal transformation, routing override) lose their home. Either moves them back to plugin `handle_signal/2` (same conflation problem) or into `on_cmd` where they can only run post-routing (wrong layer for "should this signal even be routed?"). Rejected: the two tiers genuinely do different things.

- **Four-tier middleware (before_signal / after_signal / before_cmd / after_cmd).** Redux middleware is single-tier with `next` delimiting before/after; the idiom is clean and well-understood. Two tiers match the two genuine layers in Jido (pre-routing, around-cmd). Four adds ceremony without capability. Rejected.

## Follow-ups

- Port in-repo plugin `handle_signal/2` and `transform_result/3` usages to middleware.
- Replace `error_policy` config across the codebase (and its corresponding state fields) with middleware composition.
- Retire `on_before_cmd/2` / `on_after_cmd/3`; migrate in-repo usages.
- Write `guides/middleware.md` with the contract, standard library, and migration recipes.
- Evaluate whether a typed `Observable` behaviour (plugin-level status reporting) is worth formalizing — tracked separately; not required for this ADR.
