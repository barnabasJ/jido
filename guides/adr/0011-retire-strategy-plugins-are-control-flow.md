# 0011. Retire `Strategy`; control-flow patterns live as plugins

- Status: Proposed
- Implementation: Pending
- Date: 2026-04-22
- Related commits: —

## Context

After ADRs [0005](0005-agent-domain-as-a-state-slice.md)/[0008](0008-flat-layout-removed.md) (the `:__domain__` slice became the default) and [0009](0009-inline-signal-processing.md) (signal processing inlined; directives are the only effect descriptor), `Agent.cmd/2` took the exact shape of an Elm `update`:

```
update : Msg -> Model -> (Model, Cmd Msg)
```

Signal ≡ Msg. Directive ≡ Cmd. AgentServer ≡ Elm runtime. The spawn-task-emit-signal pattern from 0009 is the Cmd-executed-by-runtime-returns-as-Msg loop.

In this shape, `Jido.Agent.Strategy` is a hybrid that no longer earns its own concept:

- Strategy owns its own slice (`:__strategy__`) — the same pattern plugins already use (`:__pod__`, `:__bus_wiring__`, etc.).
- Strategy has `signal_routes/1` — duplicate of the plugin callback with the same name.
- Strategy has `init/2` (called twice, with an unwritten idempotency contract) — duplicate of the plugin `mount/2` / post-0007 `after_start/1` shape.
- Strategy has `snapshot/2` — a naming convention that plugins could equally provide as a helper.
- `Jido.Agent.Strategy.Direct` (the default, 142 lines at [lib/jido/agent/strategy/direct.ex](../../lib/jido/agent/strategy/direct.ex)) implements slice-result application — which, post-0008, is the canonical behaviour of `cmd/2`, not a strategy choice.

The three benefits Strategy earns over "no strategy" (reusability across agents, separated execution state, a typed status snapshot) are all already provided by Plugin. The distinction between Strategy and Plugin is convention, not capability. Meanwhile, FSM — the only non-trivial built-in strategy — is shaped exactly like a plugin: a slice holding machine state, actions that validate transitions, routes that handle transition signals.

## Decision

**Strategy retires. Control-flow patterns (FSM, ReAct, behavior trees, planners) are plugins.**

Concretely:

1. **Remove `Jido.Agent.Strategy`** (behaviour at [lib/jido/agent/strategy.ex](../../lib/jido/agent/strategy.ex)) and `lib/jido/agent/strategy/` in its entirety. `use Jido.Agent, strategy: ...` becomes a compile-time error.

2. **Remove the `:__strategy__` reserved state key.** No framework-owned slice; strategies that needed state can own a plugin slice like any other plugin.

3. **Inline `Direct`'s slice-result application into `Agent.cmd/2`.** The logic at `direct.ex:74-141` — resolve `state_key`, extract the slice, run the action, apply whole-slice-replace (ScopedAction) or deep-merge (non-scoped) — becomes the canonical behaviour of `cmd/2` directly. No named wrapper.

4. **Port `Jido.Agent.Strategy.FSM` to `Jido.Plugin.FSM`.** Slice `:__fsm__`. Machine configuration passes via plugin config. Transition validation lives in its actions. External callers read FSM state via `Jido.Plugin.FSM.current_state/1` (plugin helper), not `strategy_snapshot/1`.

5. **Drop `strategy_snapshot/1` from the agent surface.** Plugins that track execution state expose their own status helpers.

6. **The Strategy "instruction tracking" helper** ([lib/jido/agent/strategy/instruction_tracking.ex](../../lib/jido/agent/strategy/instruction_tracking.ex)) moves into the middleware pipeline (per [ADR 0012](0012-middleware-for-cross-cutting-concerns.md)) or inlines into agents that want it. It was never strategy-specific.

## Consequences

- **One fewer top-level concept.** The extension story becomes: *actions* transform slices; *plugins* add capabilities (state + actions + routes); *middleware* (0012) wraps execution with cross-cutting concerns; the agent's own `cmd/2` is the pure update function. No separate "execution strategy" layer.

- **`cmd/2` becomes Elm-shaped by construction.** Slice application is structural, not policy. Custom agents write actions; advanced control flow (FSM, ReAct, BT, planners) lives as plugins with their own slices and routes.

- **Plugins are now the home for complex control patterns.** Their existing surface (slice + actions + `signal_routes` + post-0007 `after_start`) is expressive enough — the "Can ReAct be a plugin?" sketch in the plan doc confirms it end-to-end. Nothing new is needed on the plugin side for this ADR.

- **Hand-rolled single-flight locks in plugins become redundant.** Under [ADR 0009](0009-inline-signal-processing.md)'s inline signal processing the agent mailbox serializes signal handling; an in-state status flag in the plugin's own slice is the authoritative "in progress?" check. The Pod plugin's external ETS mutation lock ([lib/jido/pod/mutable.ex](../../lib/jido/pod/mutable.ex) — `:jido_pod_mutation_locks`) is an artifact of pre-0009 orchestration and retires alongside Strategy. Concretely: the `Mutate` action reads `:__pod__.mutation.status`, returns a `:mutation_in_progress` reply directive if `:running`, otherwise emits `StateOp` directives that flip status and the `%ApplyMutation{}` directive. This ties off the `Pod.Mutable.mutate/3` follow-up flagged by [ADR 0006](0006-external-sync-uses-signals.md).

- **Plugin routes on lifecycle signals (e.g. `"jido.agent.started"`) are multicast.** The signal router returns a *list* of matching targets and runs every matched action ([lib/jido/agent_server.ex:1760](../../lib/jido/agent_server.ex:1760)). Ordering between matched routes within the Plugin priority tier (-10) is not specified. Plugin boot actions (and other lifecycle-routed actions) must not depend on each other's slice state. Slice boundaries from [ADR 0008](0008-flat-layout-removed.md) already disallow cross-slice reads, so this is a discipline clarification rather than a new constraint.

- **Breaking change for any agent declaring `strategy:`.** Migration: drop the option for agents that used Direct (it's the default); migrate `strategy: {FSM, opts}` agents to `plugins: [{Jido.Plugin.FSM, opts}]`; migrate custom strategies to custom plugins. All in-repo sites are updated; there are no external users.

- **The `:__strategy__` key is no longer reserved.** Existing persisted state containing the key will be ignored on load (same shape as stale plugin state). No on-disk migration needed because nothing depends on the key post-removal.

- **`strategy_snapshot/1` callers migrate to plugin-specific helpers.** External observers (dashboards, tests) that asked "is this agent done?" now call a plugin-specific function. A typed `Observable` behaviour across plugins is a follow-up, not part of this ADR.

- **`Jido.Agent.Strategy.State` helpers disappear.** Plugins manipulate their own slice directly via `agent.state[plugin.state_key]` or via `put_in/3` / `update_in/2`, same as every other plugin does today.

- **Guides shift.** `guides/strategies.md` and `guides/custom-strategies.md` retire; their content about control-flow patterns moves under updated `guides/plugins.md`, with a worked FSM-as-plugin example and a pointer to the ReAct-as-plugin reference in `test/examples/`.

## Alternatives considered

- **Keep Strategy, narrow it to just control-flow.** Direct disappears into core (same as here); Strategy becomes a tight control-flow callback only. Less disruptive for the surface area but keeps a parallel concept for what plugins already express. Forces future authors to ask "plugin or strategy?" for every new control pattern. Rejected: the parallel concept carries ongoing cognitive cost for no capability gain.

- **Unify Strategy + Plugin under a single umbrella.** Largest refactor: one extension concept with a "this is the execution policy" slot. Muddies Plugin's "adds capability" story by conflating it with "controls execution." Rejected: premature unification; Plugin already absorbs the cases Strategy serves without needing a privileged slot.

- **Keep `Direct` as a named strategy; retire only FSM and custom strategies.** Inconsistent: Direct is a no-op wrapper around core behaviour, and keeping it forces every agent to carry the declaration for no benefit. Rejected.

- **Leave Strategy in place; only document plugins as the preferred extension point.** Documentation-only fix. Doesn't resolve the `:__strategy__` vs. plugin-slice redundancy, the `signal_routes/1` duplication, or the dual-`init/2` issue. Rejected: tech debt that pays interest forever.

## Follow-ups

- [ADR 0012](0012-middleware-for-cross-cutting-concerns.md) — introduces Middleware, which absorbs the cross-cutting intercept concerns that currently sit on plugins (`handle_signal/2`, `transform_result/3`) and in `AgentServer.error_policy`. The two ADRs together yield the full "plugins are pure slices" shape.
- Port in-repo agents declaring `strategy: Direct` (the default) by removing the option.
- Port FSM-based agents to `Jido.Plugin.FSM` once the port lands.
- Write a reference ReAct-as-plugin example under `test/examples/react/` (the plan doc has the sketch).
