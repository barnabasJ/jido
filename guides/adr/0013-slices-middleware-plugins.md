# 0013. Slices, Middleware, Plugins — Redux-shaped extension vocabulary

- Status: Superseded by [0014](0014-slice-middleware-plugin.md)
- Implementation: Pending
- Date: 2026-04-23
- Related commits: —
- Supersedes: [0011](0011-retire-strategy-plugins-are-control-flow.md), [0012](0012-middleware-for-cross-cutting-concerns.md)
- Superseded-by: [0014](0014-slice-middleware-plugin.md) — the three-tier
  vocabulary (Slice / Middleware / Plugin) and path-based registration stand;
  [0014](0014-slice-middleware-plugin.md) tightens the Slice surface (no
  callbacks — `mount/2` / `on_checkpoint/2` / `on_restore/2` retire), collapses
  Middleware to a single-tier `on_signal/3` contract, renames identity signals
  to `jido.agent.identity.*`, and moves persistence onto a `Persister` middleware.

## Context

The Jido core is structurally Redux. Signals are actions; directives are effects; `cmd/2` is dispatch→reducer; each plugin owns a state slice at a compile-time `state_key`. [ADR 0008](0008-flat-layout-removed.md) made "every user-addressable value lives inside a named slice" the default. [ADR 0009](0009-inline-signal-processing.md) made inline signal processing + directives the only effect path. The shape lines up point-for-point with Redux, just without using the vocabulary.

[ADR 0011](0011-retire-strategy-plugins-are-control-flow.md) and [ADR 0012](0012-middleware-for-cross-cutting-concerns.md) were drafted to finish the alignment: retire `Jido.Agent.Strategy` (control-flow moves into plugins), introduce `Jido.Middleware` for cross-cutting concerns (plugins shed `handle_signal/2` and `transform_result/3`). Together they produce "plugins are pure Redux slices" as the outcome. Both are still Proposed / Implementation Pending.

Two things became clear reviewing the 0011+0012 pair:

1. **The vocabulary isn't named.** After 0011+0012 the framework has two extension tiers with overlapping-but-distinct surfaces (state + routes vs. cross-cutting interception) and one word — "plugin" — straddling both intents. Redux calls them "slices" and "middleware" and nobody gets confused. The framework can adopt the same names.

2. **The `:__identifier__` convention persists.** `state_key: :__thread__`, `:__domain__`, `:__pod__`, `:__bus_wiring__`. Double-underscore atoms as slice keys were a rationing strategy that predates the Redux alignment being explicit. Once every value is slice-owned (0008) and every slice is user-declared, there's no namespace to reserve against. Slices should just register at a **path** — a flat atom — the way `combineReducers` takes `{domain: domainReducer, thread: threadReducer}`.

A third observation fell out on review: the runtime fields `:__partition__`, `:__parent__`, `:__orphaned_from__` on `agent.state` are not slice state. `:__partition__` is already a typed field on `%Jido.AgentServer.State{}` ([lib/jido/pod/runtime.ex:1117](../../lib/jido/pod/runtime.ex:1117) pattern-matches it); the `agent.state` copy is a redundant mirror from callsites that only had the agent struct handy. Promoting those to slices would require either ceremony actions that satisfy the reducer invariant without carrying meaningful mutation vocabulary, or direct writes that break the invariant under a slice label. Neither is defensible; they belong on the server state where they already logically live.

## Decision

We supersede 0011 and 0012 with a single coherent spec. Three explicit tiers, path-based registration, runtime identity on `%AgentServer.State{}`, lifecycle transitions as signals.

### Three tiers

| Tier | Owns state? | Intercepts signals/cmds? | Redux analogue |
|---|---|---|---|
| **Slice** — `use Jido.Slice, path: :thread` | Yes, at a declared path | No | `createSlice` |
| **Middleware** — `use Jido.Middleware` | No (stateless) | Yes (`on_signal/3`, `on_cmd/4`) | Redux middleware |
| **Plugin** — `use Jido.Plugin, path: :chat` | Yes | Yes | Stateful middleware (bundle) |

- **Slice** — the pure shape. Declares `name`, `path`, `actions`, `schema`, `config_schema`, `signal_routes`, `subscriptions`, `schedules`, `capabilities`, `requires`. Optional lifecycle: `mount/2`, `child_spec/1`, `subscriptions/2`, dynamic `signal_routes/1`, persistence via `on_checkpoint/2` / `on_restore/2`. No interception callbacks. This is what today's `Jido.Plugin` becomes after 0012 strips the signal/cmd callbacks.

- **Middleware** — the cross-cutting shape, per 0012. Two optional callbacks:

  ```elixir
  @callback on_signal(signal, ctx, next) :: {ctx, [directive]}
  @callback on_cmd(agent, instructions, ctx, next) :: {agent, [directive]}
  ```

  Stateless by default. Middleware that needs persistent state either (a) declares a paired Slice or (b) upgrades to a Plugin.

- **Plugin** — the combo. `use Jido.Plugin` is equivalent to `use Jido.Slice` + `@behaviour Jido.Middleware`. A single module that contributes both a slice AND middleware callbacks. Used when a feature is naturally stateful *and* wants to wrap execution (e.g., circuit breakers, rate limiters with usage tracking, chat plugins that intercept token streams).

### Registration via path

Every slice is registered at a **flat atom path**. `agent.state` becomes a uniform map of slice paths — no reserved prefixes, no derivation, no `Instance.derive_state_key`:

```elixir
defmodule MyAgent do
  use Jido.Agent,
    name: "my_agent",
    path: :domain,                        # required; where agent's own schema lives
    schema: Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)}),

    slices: [
      MyApp.ThreadSlice,                  # registers at slice's declared default path
      {MyApp.ThreadSlice, path: :audit}   # same slice module, different path
    ],
    middleware: [
      Jido.Middleware.Logger,
      Jido.Middleware.Retry
    ],
    plugins: [
      MyApp.ChatPlugin                    # contributes slice + middleware
    ]
end

# agent.state = %{
#   domain:  %{counter: 0},
#   thread:  %{entries: [...]},
#   audit:   %{entries: [...]},
#   chat:    %{messages: [...]}
# }
```

The agent plays the role of Redux's `combineReducers`. Every path has exactly one owning slice.

`as:` aliasing retires. Multi-instance registration uses explicit `path:` overrides — the path IS the disambiguator.

The agent declares its own path via the required `path:` option. The `:__domain__` default from 0008 retires: every agent names its own slice.

### Middleware chain composition

The effective chain is `middleware ++ plugin_middleware_in_declaration_order`. Each middleware wraps the next; the innermost wraps the core `routing → cmd/2 → directive execution` pipeline (the pipeline shape from 0012 is unchanged). Plugin authors who need a middleware slot before user-declared middleware publish a separate middleware module alongside the slice instead of shipping a Plugin; this keeps the full chain visible in the agent's `middleware:` list.

### Runtime identity on `%AgentServer.State{}`

`:__partition__`, `:__parent__`, `:__orphaned_from__` leave `agent.state`:

- **`partition`** — already a typed field on `%Jido.AgentServer.State{}`. Drop the `agent.state[:__partition__]` mirror. Callsites (`lib/jido/pod/mutable.ex:76`, `lib/jido/observe/config.ex:161`, `lib/jido/persist.ex:493`, `lib/jido/agent_server/options.ex:170`, `lib/jido/jido.ex:623-625`) rewrite to read from server state — they already run inside AgentServer-scoped operations.

- **`parent`** — moves to `%Jido.AgentServer.State{}` as a typed field holding `%Jido.AgentServer.ParentRef{pid: ...}` or nil. `Directive.emit_to_parent/3` ([lib/jido/agent/directive.ex:1008](../../lib/jido/agent/directive.ex:1008)) pattern-matches on server state's `parent`. PIDs are runtime-only concerns; they live on the server struct where they belong.

- **`orphaned_from`** — moves to `%Jido.AgentServer.State{}` as a typed field. Set during the orphan transition when `:DOWN` arrives for the parent.

- **`:__pod_ancestry__`** — already not on `agent.state` (a private `Keyword` option in `Pod.Runtime.reconcile`). Rename to `:pod_ancestry` for consistency with the dropped prefix convention.

`put_runtime_refs/4` ([lib/jido/agent_server/state.ex:294-302](../../lib/jido/agent_server/state.ex:294-302)) — which currently mirrors these onto `agent.state` — is deleted.

### Lifecycle signals

Runtime identity transitions become observable signals. Agents/plugins/middleware that want to react subscribe through `signal_routes` like anything else:

- `jido.agent.partition.assigned` — emitted at `AgentServer.init/1` after partition is resolved; payload includes the partition value.
- `jido.agent.parent.died` — emitted when the parent process's `:DOWN` is received.
- `jido.agent.orphaned` — paired with `parent.died`; payload carries the former `%ParentRef{}` for provenance.

Signals are the observability layer; server-state fields are the source of truth. The two are independent: state lives where it makes sense; events are broadcast where subscribers can see them.

### Absorptions from 0011 and 0012

0011's absorptions stand: Strategy retires, `Jido.Agent.Strategy.Direct` inlines into `Agent.cmd/2`, FSM ports to `Jido.Plugin.FSM` at `path: :fsm`, `:__strategy__` is gone, `strategy_snapshot/1` retires.

0012's absorptions stand: plugin `handle_signal/2` → middleware `on_signal/3`; plugin `transform_result/3` → middleware `on_cmd/4` after-`next`; `error_policy` config → composable error middleware (`Logger`, `Retry`, `CircuitBreaker`, `LogErrors`, `StopOnError`, `Persister`); `on_before_cmd/2` / `on_after_cmd/3` retire.

This ADR adds to both: the vocabulary names (slice/middleware/plugin), the path-based registration, the `:__` convention retirement, and the runtime-identity migration.

## Consequences

- **Vocabulary matches Redux point-for-point.** `slice`, `middleware`, the agent as `combineReducers`. A React developer reading the codebase recognizes the shape without translation. Framework docs stop re-explaining what "plugin" means depending on context.

- **`agent.state` is a uniform map of slice paths.** Zero `__identifier__` remnants, zero runtime-metadata pollution, zero exceptions. Every value in `agent.state` has exactly one owning slice registered at a declared path. The "where can I read this?" question has one answer: `agent.state[path]`, where `path` is whatever the owning slice declared.

- **Runtime identity is first-class on the server.** `server_state.partition`, `server_state.parent`, `server_state.orphaned_from` are typed struct fields with clear semantics. The historical duplication on `agent.state` (which predates the slice model being enforced) is cleaned up. Anything that reads partition/parent already runs inside AgentServer-scoped operations and can thread the server state naturally.

- **Lifecycle transitions are observable via signals.** Anything that wants to react to partition assignment, parent death, or orphaning uses the ordinary `signal_routes` mechanism. No special API, no polling state.

- **Breaking change across the board for plugin authors.** `state_key: :__x__` → `path: :x`. `handle_signal/2` → middleware `on_signal/3`. `transform_result/3` → middleware `on_cmd/4`. `as:` aliasing → explicit `path:` override. Every existing plugin migrates; recipes are mechanical. In-repo plugins (Thread, Identity, Memory, Pod, BusPlugin) are migrated with this ADR; no external users exist.

- **Breaking change for agents.** `use Jido.Agent, state_key: :__domain__` → `use Jido.Agent, path: :domain` (required). `agent.state.__domain__.X` → `agent.state.DECLARED_PATH.X`. Scoped actions `use Jido.Agent.ScopedAction, state_key: :foo` → `path: :foo`.

- **Persistence touches real on-disk data.** Pre-refactor persisted state has `%{__domain__: ..., __thread__: ..., __partition__: ...}` written. `Jido.Persist.thaw/3` gains a migration pass that rewrites old keys to user-declared paths using the agent module's path map; `__partition__`/`__parent__`/`__orphaned_from__` are discarded on load because they're reconstructed at server spawn.

- **Plugin callers lose "intercept from anywhere."** A slice can no longer swallow or rewrite a signal — that's middleware territory now. If a built-in slice today leans on `handle_signal/2` it splits into a Slice + Middleware pair (or becomes a Plugin, if it makes sense to bundle).

- **One fewer top-level concept, then three.** Strategy retires. Slice, Middleware, Plugin replace the current `{Strategy, Plugin}` ambiguity. Three concepts, each with one job, naming aligned to a widely-known prior art.

## Alternatives considered

- **Land 0011 and 0012 as drafted; rename later.** Two migrations instead of one. Every plugin gets migrated to the post-0011+0012 shape, then migrated again when `Slice` and `Path` land. Rejected: the ADRs are Proposed with zero implementation, so there's no sunk cost to preserve.

- **Keep `:__domain__` as a reserved default.** Every agent still implicitly has a `:__domain__` slice unless it opts out. Smaller surface break for in-repo agents. Rejected: the `__identifier__` cleanup is the point. An auto-default that reintroduces a magic atom defeats the uniformity property.

- **Make runtime keys into framework-declared slices.** `:partition`, `:parent`, `:orphaned_from` become slices the framework auto-registers. Uniform shape for `agent.state`. Rejected: forces either ceremony actions (`SetPartition`, `Orphan`) that satisfy the reducer invariant without carrying meaningful mutation vocabulary, or direct writes that break the invariant under a slice label. Runtime identity genuinely isn't store state; pretending it is costs ceremony and clarity. Server-state fields are the honest home.

- **Nested path lists or dotted strings.** `path: [:system, :thread]` or `path: "system.thread"` → `state.system.thread`. More organizational capability. Rejected: flat atoms match `combineReducers` exactly, keep state shape trivially introspectable, and sidestep "what happens when two slices register overlapping nested paths" questions. Agents that want grouping can name paths `:system_thread` themselves.

- **Separate slice and middleware modules always — no Plugin combo.** Forces every stateful cross-cutting concern to ship two modules. Rejected: bundling is ergonomic and honest. A rate-limiter that owns usage state AND wraps `on_cmd` is one feature, not two; forcing two module declarations adds ceremony without clarifying the design. `use Jido.Plugin` signals "I'm both" in one place.

- **Keep `as:` aliasing as sugar over path.** `{ChatSlice, as: :support}` desugars to `path: :support_chat` (or similar). Two ways to do the same thing. Rejected: the path IS the disambiguator; no derivation logic earns its keep once paths are explicit.

## Follow-ups

- Write `guides/slices.md`, `guides/middleware.md`, `guides/plugins.md` (rewrite). Retire `guides/strategies.md`, `guides/custom-strategies.md`.
- Migrate in-repo plugins (Thread, Identity, Memory, Pod, BusPlugin) to `use Jido.Slice` or `use Jido.Plugin` as appropriate.
- Port `Jido.Agent.Strategy.FSM` to `Jido.Plugin.FSM` at `path: :fsm`; inline `Direct` into `Agent.cmd/2`.
- Ship the standard middleware library per 0012 (`Logger`, `Retry`, `CircuitBreaker`, `LogErrors`, `StopOnError`, `Persister`) under `lib/jido/middleware/`.
- Persistence migration pass in `Jido.Persist.thaw/3`: rewrite pre-refactor `:__domain__` / `:__thread__` / ... keys to user-declared paths; discard runtime-identity keys.
- Write a reference ReAct-as-Plugin example under `test/examples/react/` to exercise the Plugin combo shape end-to-end.
- Update ADRs 0011 and 0012 headers to `Status: Superseded by 0013`, add pointers back here.
