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
                      opts :: map(),
                      next :: (Signal.t(), map() -> {map(), [Directive.t()]})) ::
              {map(), [Directive.t()]}

  @optional_callbacks on_signal: 4
end
```

Four args: `signal`, `ctx` (per-signal runtime context), `opts` (compile-time options captured via closure at chain-build time from `{Mod, opts}` registrations), and `next` (continuation). `next` runs the full inner pipeline: routing → `cmd/2` → directive execution. Each middleware wraps `next`; the outermost wraps the whole chain. To gate, transform, retry, or swallow, do it around the `next` call. To reject, don't call `next` and emit an `%Error{}` directive (or similar) instead.

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
  def on_signal(signal, ctx, _opts, next) do
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
  → Retry.on_signal(signal, ctx, plugin_next)
     → ChatPlugin.on_signal(signal, ctx, core_next)
        → core: routing → cmd/2 → directive execution
```

Effective chain is `middleware ++ plugin_middleware_in_declaration_order`. Each wraps the next; the innermost wraps core routing + cmd + directives.

**Emitted signals re-enter the chain.** When a directive executor fires `%Directive.Emit{signal: Y}`, Y self-casts back to the agent's mailbox and takes its own full pipeline pass — routing, chain, directives, ack. One uniform observability path; middleware doesn't distinguish externally-delivered signals from loop-backs. Ctx inherits via `signal.extensions[:jido_ctx]`. See ADR 0016:59 for the ack-boundary implication.

### Runtime identity on `%AgentServer.State{}`

Values that describe the running process — not the agent's domain — live on the server struct, not on `agent.state`:

- **`partition`** — typed field on `%Jido.AgentServer.State{}`. The `agent.state[:__partition__]` mirror retires. Callsites (`lib/jido/pod/mutable.ex:76`, `lib/jido/observe/config.ex:161`, `lib/jido/persist.ex:493`, `lib/jido/agent_server/options.ex:170`, `lib/jido/jido.ex:623-625`) read from server state.
- **`parent`** — typed field on `%Jido.AgentServer.State{}`, holds `%Jido.AgentServer.ParentRef{pid: ...}` or nil. Middleware, actions, and directive executors read it via `ctx.parent` (seeded from server state at signal receipt). The old `Directive.emit_to_parent/3` helper is **deleted** — users that want to emit to parent build `%Directive.Emit{dispatch: {:pid, target: ctx.parent.pid}}` themselves.
- **`orphaned_from`** — typed field on `%Jido.AgentServer.State{}`, set when `:DOWN` arrives for the parent.
- **`pod_ancestry`** — already not on `agent.state`; rename drops the leading `__`.

`put_runtime_refs/4` ([lib/jido/agent_server/state.ex:294-302](../../lib/jido/agent_server/state.ex:294-302)) is deleted. PIDs and runtime handles never appear in `agent.state`.

### Identity-transition signals

Runtime-identity changes emit observable signals. Anything that wants to react subscribes via `signal_routes`:

- `jido.agent.identity.partition_assigned` — emitted at `AgentServer.init/1` after partition is resolved; payload includes the partition value.
- `jido.agent.identity.parent_died` — emitted when the parent process's `:DOWN` is received.
- `jido.agent.identity.orphaned` — paired with `parent.died`; payload carries the former `%ParentRef{}` for provenance.

These are independent of [ADR 0015](0015-agent-start-is-signal-driven.md)'s `jido.agent.lifecycle.*` family (phase-of-boot signals). Two orthogonal namespaces: `identity.*` for runtime transitions, `lifecycle.*` for boot phase. Both are ordinary signals; both route through `signal_routes` like any other.

### Persistence is blocking middleware

`Jido.Middleware.Persister` is a middleware-only module (no Slice, no `agent.state` footprint) whose `on_signal/4` pattern-matches `lifecycle.starting` / `lifecycle.stopping` and blocks synchronously on `Jido.Persist.thaw/3` / `hibernate/4`:

- **On starting**: blocks on `Jido.Persist.thaw/3`, applies `reinstate/1` callbacks via the `Jido.Persist.Transform` behaviour walk, mutates `ctx.agent` with the thawed struct, calls `next`.
- **On stopping**: applies `externalize/1` callbacks via the behaviour walk, blocks on `Jido.Persist.hibernate/4`, calls `next`.
- Emits `jido.persist.thaw.completed|failed` / `.hibernate.completed|failed` as return-side directives.

Config (storage, persistence_key) lives in the middleware's `opts` arg, captured by closure at chain-build time. Blocking IO lands on the mailbox path — acceptable trade-off since lifecycle emissions are rare and one-shot, and the consistent-in-chain-view property (every downstream middleware sees post-thaw `ctx.agent` in the same pass) is worth the blocking cost.

**Custom shape per slice — `Jido.Persist.Transform` behaviour**: slices that need a different on-disk shape than in-memory (e.g., Thread writing journal entries to external storage and persisting only a pointer) declare the behaviour directly:

```elixir
defmodule Jido.Thread.Plugin do
  use Jido.Slice, name: "thread", path: :thread, ...
  @behaviour Jido.Persist.Transform

  @impl Jido.Persist.Transform
  def externalize(thread), do: # flush + return pointer
  @impl Jido.Persist.Transform
  def reinstate(pointer), do: # rehydrate
end
```

Persister middleware walks every declared slice/plugin at hibernate/thaw and applies the callbacks of any module that implements the behaviour. `Jido.Persist.thaw/3` and `hibernate/4` stay unchanged; transform logic is purely a Persister-middleware concern.

Slices without persistence-shape concerns don't declare the behaviour; `function_exported?` skips them at walk time. No `to_persistable/1`, `from_persistable/1`, `on_checkpoint/2`, `on_restore/2` callbacks exist in the Slice surface. Pre-refactor on-disk checkpoints are **not forward-compatible** — per the "no external users exist" assumption, no migration pass ships; fresh checkpoints only.

### Start-time setup is a signal route

Components that need to do work at boot subscribe to `jido.agent.lifecycle.starting` or `jido.agent.lifecycle.ready` (signals defined in [ADR 0015](0015-agent-start-is-signal-driven.md)) via `signal_routes`. A Slice adds a route pointing at one of its actions. A Plugin either adds a Slice-side route or observes the signal in its `on_signal` middleware. No dedicated start-time callback exists because the signal itself is the hook.

### Absorptions from 0011 and 0012 that stand

These decisions were correct in the superseded ADRs and remain in force:

- `Jido.Agent.Strategy` retires. `Direct` inlines into `Agent.cmd/2`. `:__strategy__` is gone. `strategy_snapshot/1` retires. FSM ports to `Jido.Plugin.FSM` at `path: :fsm`.
- `handle_signal/2` → `on_signal/4` before-`next`.
- `transform_result/3` → `on_signal/4` after-`next`.
- `error_policy` config → composable middleware. This PR ships only `Jido.Middleware.Retry`; the error-handling replacement (`LogErrors`, `StopOnError`) is deferred to a follow-up PR. `Persister` ships as a Plugin (see "Persistence is a Plugin concern"), not middleware.
- `on_before_cmd/2` / `on_after_cmd/3` retire; their uses land in middleware.
- In-repo plugins (Thread, Identity, Memory, Pod, BusPlugin) migrate to Slice or Plugin as appropriate.

## Consequences

- **Redux analogy is exact.** Slice = `createSlice` (declarative config). Middleware = Redux middleware (single-tier `next`-passing). Agent = `combineReducers`. A React developer reading the codebase recognizes the shape without translation.

- **Slice is a honest pure type.** No hidden methods to discover by searching module definitions. Everything a Slice can contribute is in its `use` block. This is the biggest ergonomic win over 0013: readers know what's there by looking at the declaration, not by grepping for callbacks.

- **Middleware is one thing, not two.** `on_signal/4` alone covers gate, transform, retry, persist, circuit-break, error-log-and-convert. The mental model is "wrap the pipeline," identical to Redux. Plugin authors who need a layered effect compose middleware modules in the chain — the composition is user-declared and visible at the agent declaration site.

- **`agent.state` is uniform.** Flat atom paths, one owning slice each, no `__identifier__` anywhere. `agent.state[path]` is the single answer to "where is X?"

- **Runtime identity lives where it belongs.** `server_state.partition`, `server_state.parent`, `server_state.orphaned_from` are typed struct fields. `agent.state` is purely domain/slice state. The historical duplication disappears.

- **Observable lifecycle and identity.** Both `jido.agent.lifecycle.*` (0015) and `jido.agent.identity.*` (this ADR) are ordinary signals. No special API to subscribe; no polling. If you care, add a route.

- **Breaking change across the plugin author surface.** Every existing plugin migrates:
  - `state_key: :__x__` → `path: :x`.
  - `handle_signal/2` → `on_signal/4` before-`next`.
  - `transform_result/3` → `on_signal/4` after-`next`.
  - `on_checkpoint/2` / `on_restore/2` → declare a `transforms:` entry in the `Jido.Middleware.Persister` config (MFA per path).
  - `mount/2` / dynamic lifecycle → Slice actions routed from `jido.agent.lifecycle.*`.
  - `as:` → explicit `path:`.
  Recipes are mechanical. In-repo plugins are migrated with this ADR. No external users exist.

- **Breaking change for agents.** `use Jido.Agent, state_key: :__domain__` → `use Jido.Agent, path: :domain` (required). `agent.state.__domain__.X` → `agent.state.DECLARED_PATH.X`. Scoped actions `use Jido.Agent.ScopedAction, state_key: :foo` → `path: :foo`.

- **Pre-refactor persisted state is abandoned.** Old shape `%{__domain__: ..., __thread__: ..., __partition__: ...}` is unreadable by post-refactor code. Per "no external users exist," no migration pass ships; local dev / test fixtures regenerate on first run against the new code. Runtime keys (`__partition__`/`__parent__`/`__orphaned_from__`) are stripped at hibernate time going forward, since they're runtime state reconstructed at server spawn.

- **Three concepts, each with one job.** Slice owns state shape. Middleware wraps execution. Plugin bundles both when they belong together. Strategy retires (0011). The "plugin or strategy?" question disappears.

## Alternatives considered

- **Amend 0013 in place rather than supersede.** Smaller diff in the ADR set. Rejected: the Slice surface change (all callbacks out) and the middleware-tier change (two → one) are material enough that 0013's prose would contradict the amendment throughout. A fresh write-up reads honestly; 0013 keeps its decision trail as a pointer.

- **Keep Slice lifecycle callbacks (`mount/2`, `on_checkpoint/2`, `on_restore/2`).** Matches what most frameworks do. Rejected: it means "Slice" is not actually a pure type; readers can't trust the `use` block to describe everything the module contributes. The Plugin tier exists precisely to absorb these cases without diluting Slice.

- **Keep Middleware two-tier (`on_signal/3` + `on_cmd/4`).** The justification in 0012 was "signal-layer concerns and cmd-layer concerns genuinely differ." Reviewing the concrete cases, they don't — every cross-cutting concern fits a single `next`-passing contract. Rejected: added ceremony without capability.

- **Keep `:__domain__` as a reserved default.** Smaller break for in-repo agents. Rejected: `__identifier__` cleanup is the point. An auto-default that reintroduces a magic atom defeats uniformity.

- **Make runtime keys (`:partition`, `:parent`, `:orphaned_from`) into framework-declared slices.** Uniform shape for `agent.state`. Rejected: forces either ceremony actions that satisfy the reducer invariant without carrying meaningful mutation vocabulary, or direct writes that break the invariant under a slice label. Runtime identity genuinely isn't store state.

- **Nested path lists or dotted strings (`path: [:system, :thread]`).** More organizational capability. Rejected: flat atoms match `combineReducers` exactly and sidestep "what happens when two slices register overlapping nested paths" questions. Agents that want grouping name paths `:system_thread` themselves.

- **Persister as a pure Slice with Actions + Directives + Executors.** One interim proposal (round-4 W-G) was: Slice-only Persister whose actions route on `lifecycle.starting/.stopping`, emit `%Directive.Thaw{}` / `%Directive.Hibernate{}`, with executors running IO after the chain unwinds. Keeps IO off the mailbox hot path. Rejected (round-4 pivot): the action+directive approach runs IO *after* the chain unwinds, so any middleware observing `lifecycle.starting` sees pre-thaw `ctx.agent` in the same pass — inconsistent with the "chain view" of state. Users trying to write `starting`-observing middleware would need to wait for `ready` to see thawed data. The blocking-middleware approach makes the chain view consistent within each pass at the cost of blocking-IO-on-mailbox during lifecycle. Since lifecycle is rare and one-shot, the cost is acceptable.

- **Ship the full error-handling middleware set (`LogErrors` / `StopOnError` / `Logger` / `CircuitBreaker`) in this PR.** Part of the original 0012/0013 story. Rejected: the error-handling model (what counts as an error, how directives propagate, whether `%Stop{}` is user-facing) deserves a dedicated PR after the structural refactor lands. This PR ships only `Retry` — enough to exercise the middleware pipeline end-to-end. `error_policy:` retires with no direct replacement; the migration guide includes reference snippets for users to self-roll log-and-continue or stop-on-error until the follow-up PR lands.

## Follow-ups

- Write `guides/slices.md`, `guides/middleware.md`, `guides/plugins.md` (rewrite). Retire `guides/strategies.md`, `guides/custom-strategies.md`.
- Migrate in-repo plugins (Thread, Identity, Memory, Pod, BusPlugin) to Slice or Plugin as appropriate.
- Port `Jido.Agent.Strategy.FSM` to `Jido.Plugin.FSM` at `path: :fsm`; inline `Direct` into `Agent.cmd/2`.
- Ship `Jido.Middleware.Retry` under `lib/jido/middleware/retry.ex` and `Jido.Middleware.Persister` under `lib/jido/middleware/persister.ex` (middleware-only; blocks on thaw/hibernate IO during `lifecycle.starting`/`.stopping`; config in `opts`).
- Deferred to follow-up PRs: `Logger`, `CircuitBreaker`, `LogErrors`, `StopOnError`, and the formal error-handling model.
- No persistence migration pass: old on-disk checkpoints are abandoned by design; runtime-identity keys (`__partition__`/`__parent__`/`__orphaned_from__`) are stripped at hibernate time going forward so they don't accumulate.
- Write a reference ReAct-as-Plugin example under `test/examples/react/` to exercise the Plugin combo shape end-to-end.
- Update ADRs 0007, 0010, 0013 headers with `Superseded by` pointers.
