# 0014. Slices, Middleware, Plugins — the extension model

- Status: Proposed
- Implementation: Pending
- Date: 2026-04-23
- Related commits: —
- Supersedes: [0013](0013-slices-middleware-plugins.md) (which already superseded [0011](0011-retire-strategy-plugins-are-control-flow.md), [0012](0012-middleware-for-cross-cutting-concerns.md))

## Context

The Jido core is structurally Redux. Signals are actions; directives are effects; `cmd/2` is dispatch→reducer; every user-addressable value lives inside a named state slice ([ADR 0008](0008-flat-layout-removed.md)); inline signal processing is the only effect path ([ADR 0009](0009-inline-signal-processing.md)).

[ADR 0013](0013-slices-middleware-plugins.md) began aligning the vocabulary — three tiers (Slice / Middleware / Plugin), path-based registration, runtime identity moved to `%AgentServer.State{}`. Two things, reviewed after-the-fact, need revising before implementation lands:

1. **Slices in 0013 still carried lifecycle callbacks** — `mount/2`, `on_checkpoint/2`, `on_restore/2`, dynamic `signal_routes/1`. That made "Slice" a leaky abstraction: the pure declarative reducer story on one side, behavioural hooks on the other. Readers couldn't tell from the type signature whether a Slice was "declare-and-done" or "declare-plus-methods."

2. **Middleware in 0013 was two-tier** — `on_signal/3` plus `on_cmd/4`. Reviewing the concrete cases (gate, transform, retry, persist, circuit-break, log-and-convert errors), every one of them works cleanly under a single `next`-passing contract. The two-tier split added a layer without adding capability. Redux has one tier.

Both revisions tighten the Redux analogy: Slice is pure data + transforms (like `createSlice` — config only, no behaviour methods); Middleware is a single-tier `next`-passing chain. Since 0013 is still `Status: Proposed / Implementation: Pending`, replacing rather than amending preserves the decision trail more honestly.

## Decision

Three tiers, named from Redux. Slices are pure. Middleware is single-tier. Plugin is the combo when both are needed in one module.

### Slice — pure declarative reducer, no callbacks

```elixir
defmodule MyApp.ThreadSlice do
  use Jido.Slice,
    name: "thread",
    path: :thread,
    schema: Zoi.object(%{entries: Zoi.array(Zoi.any()) |> Zoi.default([])}),
    actions: [MyApp.ThreadSlice.Append, MyApp.ThreadSlice.Clear],
    signal_routes: [
      {"thread.append", {MyApp.ThreadSlice.Append, []}},
      {"thread.clear",  {MyApp.ThreadSlice.Clear,  []}}
    ]
end
```

The full Slice surface is exactly these declarative fields:

- `name` — human-readable identifier, used in logs.
- `path` — the flat atom under which this slice's state lives in `agent.state`.
- `schema` — Zoi shape for the slice's state.
- `config_schema` — Zoi shape for compile-time options.
- `actions` — the action modules this slice contributes.
- `signal_routes` — static `signal_type → {action, opts}` mappings.
- `subscriptions` — static signal subscription declarations.
- `schedules` — static cron specs.
- `capabilities` — declared feature set.
- `requires` — dependencies on other slices.

**No callbacks.** No `mount/2`, no `on_checkpoint/2` / `on_restore/2`, no dynamic `signal_routes/1`, no `after_start/1`. A Slice is what it says it is at compile time. If something about it needs to react to runtime events, that's a middleware concern — see the Plugin tier below.

### Middleware — single-tier cross-cutting wrap

```elixir
defmodule Jido.Middleware do
  @callback on_signal(signal :: Signal.t(),
                      ctx :: map(),
                      next :: (Signal.t(), map() -> {map(), [Directive.t()]})) ::
              {map(), [Directive.t()]}

  @optional_callbacks on_signal: 3
end
```

One callback. `next` runs the full inner pipeline: routing → `cmd/2` → directive execution. Each middleware wraps `next`; the outermost wraps the whole chain. To gate, transform, retry, or swallow, do it around the `next` call. To reject, don't call `next` and emit an `%Error{}` directive (or similar) instead.

Redux middleware is single-tier. The concrete cross-cutting cases — logging, retry, persist-after, circuit-break, error conversion — all fit within "act before `next`, call `next`, act after" without needing a separate cmd-layer hook. The two-tier split 0013 proposed did not pay for itself.

Middleware is stateless by default. When persistent state is needed (e.g., circuit-breaker usage counters), the middleware either (a) ships paired with a Slice, or (b) becomes a Plugin.

### Plugin — Slice + Middleware in one module

```elixir
defmodule MyApp.ChatPlugin do
  use Jido.Plugin,
    path: :chat,
    schema: Zoi.object(%{messages: Zoi.array(Zoi.any()) |> Zoi.default([])}),
    actions: [...],
    signal_routes: [...]

  @impl Jido.Middleware
  def on_signal(signal, ctx, next) do
    # e.g. token-stream interception
    next.(signal, ctx)
  end
end
```

`use Jido.Plugin` is equivalent to `use Jido.Slice` + `@behaviour Jido.Middleware`. One module contributes both a slice (with path, schema, actions, routes) and a middleware wrap. This is the honest home for features that are genuinely stateful *and* cross-cutting: rate-limiters with usage tracking, chat plugins that intercept token streams, circuit-breakers with a configurable state slice, custom persistence transforms.

### Path-based registration

`agent.state` is a uniform map of slice paths. No reserved prefixes, no `__identifier__` atoms, no `Instance.derive_state_key`:

```elixir
defmodule MyAgent do
  use Jido.Agent,
    name: "my_agent",
    path: :domain,
    schema: Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)}),

    slices: [
      MyApp.ThreadSlice,
      {MyApp.ThreadSlice, path: :audit}    # same module, different path
    ],
    middleware: [
      Jido.Middleware.Logger,
      Jido.Middleware.Retry
    ],
    plugins: [
      MyApp.ChatPlugin
    ]
end

# agent.state = %{
#   domain: %{counter: 0},
#   thread: %{entries: [...]},
#   audit:  %{entries: [...]},
#   chat:   %{messages: [...]}
# }
```

Every path has exactly one owning slice. `path:` is required on `use Jido.Agent` — the agent names its own slice, just like every other participant. The `:__domain__` default from 0008 retires.

`as:` aliasing (from the pre-0013 world) retires. Path is the disambiguator.

### Middleware chain composition

```
signal enters
  → Logger.on_signal(signal, ctx, retry_next)
     → Retry.on_signal(signal, ctx, plugin_next)
        → ChatPlugin.on_signal(signal, ctx, core_next)
           → core: routing → cmd/2 → directive execution
```

Effective chain is `middleware ++ plugin_middleware_in_declaration_order`. Each wraps the next; the innermost wraps core routing + cmd + directives.

### Runtime identity on `%AgentServer.State{}`

Values that describe the running process — not the agent's domain — live on the server struct, not on `agent.state`:

- **`partition`** — typed field on `%Jido.AgentServer.State{}`. The `agent.state[:__partition__]` mirror retires. Callsites (`lib/jido/pod/mutable.ex:76`, `lib/jido/observe/config.ex:161`, `lib/jido/persist.ex:493`, `lib/jido/agent_server/options.ex:170`, `lib/jido/jido.ex:623-625`) read from server state.
- **`parent`** — typed field on `%Jido.AgentServer.State{}`, holds `%Jido.AgentServer.ParentRef{pid: ...}` or nil. `Directive.emit_to_parent/3` reads it from server state.
- **`orphaned_from`** — typed field on `%Jido.AgentServer.State{}`, set when `:DOWN` arrives for the parent.
- **`pod_ancestry`** — already not on `agent.state`; rename drops the leading `__`.

`put_runtime_refs/4` ([lib/jido/agent_server/state.ex:294-302](../../lib/jido/agent_server/state.ex:294-302)) is deleted. PIDs and runtime handles never appear in `agent.state`.

### Identity-transition signals

Runtime-identity changes emit observable signals. Anything that wants to react subscribes via `signal_routes`:

- `jido.agent.identity.partition_assigned` — emitted at `AgentServer.init/1` after partition is resolved; payload includes the partition value.
- `jido.agent.identity.parent_died` — emitted when the parent process's `:DOWN` is received.
- `jido.agent.identity.orphaned` — paired with `parent.died`; payload carries the former `%ParentRef{}` for provenance.

These are independent of [ADR 0015](0015-agent-start-is-signal-driven.md)'s `jido.agent.lifecycle.*` family (phase-of-boot signals). Two orthogonal namespaces: `identity.*` for runtime transitions, `lifecycle.*` for boot phase. Both are ordinary signals; both route through `signal_routes` like any other.

### Persistence is a middleware concern

`Jido.Middleware.Persister` (shipped in the standard library) handles serialization. Default behaviour: write every declared path's state, verbatim, to the configured storage after `next` returns.

Custom per-path shape transforms are declared via Persister config:

```elixir
use Jido.Agent,
  ...
  middleware: [
    {Jido.Middleware.Persister, transforms: %{
      thread: {MyApp.ThreadPersister, :externalize, :reinstate}
    }}
  ]
```

…or, when the transform logic belongs with the slice, shipped as a Plugin whose middleware half implements the persistence wrap.

Slices never carry persistence callbacks. `to_persistable/1`, `from_persistable/1`, `on_checkpoint/2`, `on_restore/2` do not exist on the Slice surface. The persistence migration pass in `Jido.Persist.thaw/3` (rewriting pre-refactor `:__domain__`/`:__thread__` keys to user-declared paths) is the only concession to old on-disk data.

### Start-time setup is a signal route

Components that need to do work at boot subscribe to `jido.agent.lifecycle.starting` or `jido.agent.lifecycle.ready` (signals defined in [ADR 0015](0015-agent-start-is-signal-driven.md)) via `signal_routes`. A Slice adds a route pointing at one of its actions. A Plugin either adds a Slice-side route or observes the signal in its `on_signal` middleware. No dedicated start-time callback exists because the signal itself is the hook.

### Absorptions from 0011 and 0012 that stand

These decisions were correct in the superseded ADRs and remain in force:

- `Jido.Agent.Strategy` retires. `Direct` inlines into `Agent.cmd/2`. `:__strategy__` is gone. `strategy_snapshot/1` retires. FSM ports to `Jido.Plugin.FSM` at `path: :fsm`.
- `handle_signal/2` → `on_signal/3` before-`next`.
- `transform_result/3` → `on_signal/3` after-`next`.
- `error_policy` config → composable error middleware (`Logger`, `Retry`, `CircuitBreaker`, `LogErrors`, `StopOnError`, `Persister`).
- `on_before_cmd/2` / `on_after_cmd/3` retire; their uses land in middleware.
- In-repo plugins (Thread, Identity, Memory, Pod, BusPlugin) migrate to Slice or Plugin as appropriate.

## Consequences

- **Redux analogy is exact.** Slice = `createSlice` (declarative config). Middleware = Redux middleware (single-tier `next`-passing). Agent = `combineReducers`. A React developer reading the codebase recognizes the shape without translation.

- **Slice is a honest pure type.** No hidden methods to discover by searching module definitions. Everything a Slice can contribute is in its `use` block. This is the biggest ergonomic win over 0013: readers know what's there by looking at the declaration, not by grepping for callbacks.

- **Middleware is one thing, not two.** `on_signal/3` alone covers gate, transform, retry, persist, circuit-break, error-log-and-convert. The mental model is "wrap the pipeline," identical to Redux. Plugin authors who need a layered effect compose middleware modules in the chain — the composition is user-declared and visible at the agent declaration site.

- **`agent.state` is uniform.** Flat atom paths, one owning slice each, no `__identifier__` anywhere. `agent.state[path]` is the single answer to "where is X?"

- **Runtime identity lives where it belongs.** `server_state.partition`, `server_state.parent`, `server_state.orphaned_from` are typed struct fields. `agent.state` is purely domain/slice state. The historical duplication disappears.

- **Observable lifecycle and identity.** Both `jido.agent.lifecycle.*` (0015) and `jido.agent.identity.*` (this ADR) are ordinary signals. No special API to subscribe; no polling. If you care, add a route.

- **Breaking change across the plugin author surface.** Every existing plugin migrates:
  - `state_key: :__x__` → `path: :x`.
  - `handle_signal/2` → `on_signal/3` before-`next`.
  - `transform_result/3` → `on_signal/3` after-`next`.
  - `on_checkpoint/2` / `on_restore/2` → move to a Plugin's middleware (or Persister config).
  - `mount/2` / dynamic lifecycle → Slice actions routed from `jido.agent.lifecycle.*`.
  - `as:` → explicit `path:`.
  Recipes are mechanical. In-repo plugins are migrated with this ADR. No external users exist.

- **Breaking change for agents.** `use Jido.Agent, state_key: :__domain__` → `use Jido.Agent, path: :domain` (required). `agent.state.__domain__.X` → `agent.state.DECLARED_PATH.X`. Scoped actions `use Jido.Agent.ScopedAction, state_key: :foo` → `path: :foo`.

- **Persistence touches real on-disk data.** Pre-refactor persisted state has `%{__domain__: ..., __thread__: ..., __partition__: ...}`. `Jido.Persist.thaw/3` gains a migration pass that rewrites old keys to user-declared paths using the agent module's path map; `__partition__`/`__parent__`/`__orphaned_from__` are discarded on load because they're reconstructed at server spawn.

- **Three concepts, each with one job.** Slice owns state shape. Middleware wraps execution. Plugin bundles both when they belong together. Strategy retires (0011). The "plugin or strategy?" question disappears.

## Alternatives considered

- **Amend 0013 in place rather than supersede.** Smaller diff in the ADR set. Rejected: the Slice surface change (all callbacks out) and the middleware-tier change (two → one) are material enough that 0013's prose would contradict the amendment throughout. A fresh write-up reads honestly; 0013 keeps its decision trail as a pointer.

- **Keep Slice lifecycle callbacks (`mount/2`, `on_checkpoint/2`, `on_restore/2`).** Matches what most frameworks do. Rejected: it means "Slice" is not actually a pure type; readers can't trust the `use` block to describe everything the module contributes. The Plugin tier exists precisely to absorb these cases without diluting Slice.

- **Keep Middleware two-tier (`on_signal/3` + `on_cmd/4`).** The justification in 0012 was "signal-layer concerns and cmd-layer concerns genuinely differ." Reviewing the concrete cases, they don't — every cross-cutting concern fits a single `next`-passing contract. Rejected: added ceremony without capability.

- **Keep `:__domain__` as a reserved default.** Smaller break for in-repo agents. Rejected: `__identifier__` cleanup is the point. An auto-default that reintroduces a magic atom defeats uniformity.

- **Make runtime keys (`:partition`, `:parent`, `:orphaned_from`) into framework-declared slices.** Uniform shape for `agent.state`. Rejected: forces either ceremony actions that satisfy the reducer invariant without carrying meaningful mutation vocabulary, or direct writes that break the invariant under a slice label. Runtime identity genuinely isn't store state.

- **Nested path lists or dotted strings (`path: [:system, :thread]`).** More organizational capability. Rejected: flat atoms match `combineReducers` exactly and sidestep "what happens when two slices register overlapping nested paths" questions. Agents that want grouping name paths `:system_thread` themselves.

## Follow-ups

- Write `guides/slices.md`, `guides/middleware.md`, `guides/plugins.md` (rewrite). Retire `guides/strategies.md`, `guides/custom-strategies.md`.
- Migrate in-repo plugins (Thread, Identity, Memory, Pod, BusPlugin) to Slice or Plugin as appropriate.
- Port `Jido.Agent.Strategy.FSM` to `Jido.Plugin.FSM` at `path: :fsm`; inline `Direct` into `Agent.cmd/2`.
- Ship the standard middleware library under `lib/jido/middleware/`: `Logger`, `Retry`, `CircuitBreaker`, `LogErrors`, `StopOnError`, `Persister`.
- Persistence migration pass in `Jido.Persist.thaw/3`: rewrite `:__domain__` / `:__thread__` / ... to user-declared paths; discard runtime-identity keys.
- Write a reference ReAct-as-Plugin example under `test/examples/react/` to exercise the Plugin combo shape end-to-end.
- Update ADRs 0007, 0010, 0013 headers with `Superseded by` pointers.
