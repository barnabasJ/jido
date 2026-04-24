# Task 0003 — Retire `Jido.Agent.Strategy`; inline Direct; port FSM to Plugin

- Commit #: 3 of 9
- Implements: [ADR 0014](../adr/0014-slice-middleware-plugin.md) — Strategy retirement (absorbed from 0011)
- Depends on: 0000, 0001, 0002
- Blocks: 0004, 0005
- Leaves tree: **red** (FSM tests fail until C8 rewrites them; Direct-strategy tests fail similarly)

## Goal

Delete the `Jido.Agent.Strategy` abstraction entirely. Inline the `Direct` implementation directly into `Agent.cmd/2`. Port `Jido.Agent.Strategy.FSM` to `Jido.Plugin.FSM` at `path: :fsm`. After this commit, there is no `strategy:` option, no `strategy_init`, no `strategy_snapshot`, and no `:__strategy__` slice anywhere in the live code.

## Files to delete

- `lib/jido/agent/strategy.ex`
- `lib/jido/agent/strategy/direct.ex`
- `lib/jido/agent/strategy/state.ex`
- `lib/jido/agent/strategy/instruction_tracking.ex`
- `lib/jido/agent/strategy/fsm.ex` — content moves to the new `lib/jido/plugin/fsm.ex` (see below)
- **`lib/jido/agent_server/status.ex`** — entire module deleted per W8. The `Jido.AgentServer.Status` struct and its helpers (`status/1`, `done?/1`, `result/1`, `details/1`, `iteration/1`, `termination_reason/1`, `queue_length/1`, `active_requests/1`) are all strategy-snapshot-coupled; no consumers outside the tests and the retiring FSM livemd.

## Files to create

### `lib/jido/plugin/fsm.ex`

Reimplementation of today's FSM strategy ([lib/jido/agent/strategy/fsm.ex](../../lib/jido/agent/strategy/fsm.ex), 386 LoC) as a `use Jido.Plugin` module at `path: :fsm`.

- Slice side declares:
  - `name: "fsm"`, `path: :fsm`
  - `schema: Zoi.object(%{state: ..., history: ..., terminal?: ...})` — whatever the current FSM struct shape in [lib/jido/agent/strategy/state.ex](../../lib/jido/agent/strategy/state.ex) has
  - `actions: [Jido.Plugin.FSM.Transition, Jido.Plugin.FSM.Tick, ...]` — ported from existing FSM action modules
  - `signal_routes:` — mirror whatever routes FSM registers today
- Middleware side (if needed): any cross-cutting hook the old FSM strategy provided on cmd-entry/exit goes into `on_signal/4`. Most of FSM's mutation happens through ordinary action dispatch; confirm during port whether a middleware half is actually necessary, and omit it if not (in that case it's a pure Slice, not a Plugin).

The FSM port must preserve semantic behavior covered by the existing test suite ([test/jido/agent/strategy_fsm_test.exs](../../test/jido/agent/strategy_fsm_test.exs) — 448 lines; full suite rewrites against `path: :fsm` in C8).

### `test/jido/plugin/fsm_smoke_test.exs` — minimal smoke tests in C3

The full FSM test suite is red through C8 (it references `Jido.Agent.Strategy.FSM`, deleted in this commit). Without a verification gate, a bug in the port manifests as a C8 test failure that looks indistinguishable from a test-rewrite bug. Ship a small smoke-test file in C3 to give the port a green gate:

```elixir
defmodule Jido.Plugin.FSMSmokeTest do
  use ExUnit.Case, async: true
  # 3-5 tests — intentionally narrow, not full coverage:
  # 1. An agent declaring `plugins: [Jido.Plugin.FSM]` starts successfully.
  # 2. A basic transition (initial → intermediate) via routed signal mutates `agent.state.fsm.state`.
  # 3. A terminal transition sets `agent.state.fsm.terminal?` to true.
  # 4. History tracking: after N transitions, `agent.state.fsm.history` has N entries.
  # 5. (If middleware half kept) cmd-entry hook fires the expected side effect.
end
```

These are written fresh against the new `Jido.Plugin.FSM` surface; they pass in C3 even while the legacy `strategy_fsm_test.exs` (448 lines) is red. C8 rewrites the full suite and either keeps or collapses this smoke test depending on coverage overlap.

## Files to modify

### `lib/jido/agent.ex`

- Remove `strategy:` and `strategy_opts:` from `@agent_config_schema` ([lines 293-298](../../lib/jido/agent.ex)).
- Remove the strategy-related accessors and their callers (search for `strategy`, `strategy_opts`, `strategy_snapshot` inside the file).
- `cmd/2` currently delegates the reducer loop to `strategy.cmd(agent, instructions, ctx)`. Inline that loop directly — the whole body of `Jido.Agent.Strategy.Direct.cmd/3` ([lib/jido/agent/strategy/direct.ex:39-49](../../lib/jido/agent/strategy/direct.ex)) becomes the body of `Agent.cmd/2`. Along with:
  - `run_instruction_with_tracking/3` ([direct.ex:62-72](../../lib/jido/agent/strategy/direct.ex))
  - `run_instruction/3` ([direct.ex:74-107](../../lib/jido/agent/strategy/direct.ex))
  - `resolve_state_key/2` → `resolve_path/2` ([direct.ex:114-123](../../lib/jido/agent/strategy/direct.ex)) — but simpler now since every action declares `path:` (per C0, `ScopedAction` folded into `Action`). Lookup is unconditional `action.path()`.
  - `apply_slice_result/5` ([direct.ex:126-141](../../lib/jido/agent/strategy/direct.ex)) — **simpler**: the non-scoped `deep-merge` branch (lines 135-141) is **deleted**. Every action returns a full new slice per C0's no-merge rule. Only the wholesale-replace path survives:
    ```elixir
    defp apply_slice_result(agent, path, new_slice, directives) do
      slice_op = %StateOp.SetPath{path: [path], value: new_slice}
      {agent, ops_directives} = StateOps.apply_state_ops(agent, [slice_op | directives])
      {agent, ops_directives, :ok}
    end
    ```
- Actions are invoked with `run(signal, slice, opts, ctx)` per C0. Build the 4-arg invocation in the inlined loop:
  ```elixir
  slice = Map.get(agent.state, action.path(), %{})
  case action.run(signal, slice, opts, ctx) do
    {:ok, new_slice} -> apply_slice_result(agent, action.path(), new_slice, [])
    {:ok, new_slice, directives} -> apply_slice_result(agent, action.path(), new_slice, directives)
    {:error, reason} -> {agent, [%Directive.Error{error: ..., context: :instruction}], :error}
  end
  ```
- The thread-tracking optional extras (`maybe_ensure_thread`, `InstructionTracking.*`) also move inline. `ThreadAgent.has_thread?/1` is preserved in the Thread module; only the strategy-side glue is deleted.
- Drop the `on_before_cmd` / `on_after_cmd` callback points entirely from `cmd/2`'s body (C4 will also drop their `@callback` declarations). Migration for agents that used them: subscribe to `jido.agent.lifecycle.ready` or add a middleware. None of the in-tree agents use these today.

### `lib/jido/agent_server.ex`

- Delete the strategy-init step in `handle_continue(:post_init)` ([lines 1022-1048](../../lib/jido/agent_server.ex)). The whole block that does `strategy.init(state.agent, ctx)` and executes the returned directives goes away.
- Delete `strategy_snapshot` invocation at [line 512](../../lib/jido/agent_server.ex) and anywhere else it reads from the agent module.
- Delete `init_signal/0` helper ([line 1079-1081](../../lib/jido/agent_server.ex)) — emitted only by strategy init. The new `jido.agent.lifecycle.starting` signal (C6) replaces its role as "init happening" marker, but that signal is emitted by the server itself from `init/1`, not by the old init step.
- **Delete `status/1` public function** ([lines 507-520+](../../lib/jido/agent_server.ex)) per W8. Users call `AgentServer.state/1` instead and derive whatever status shape they want.
- **Delete `infer_timeout_hint/1`** ([lines 469-476](../../lib/jido/agent_server.ex)) — maps Strategy status atoms to hint strings; obsolete with Strategy gone.
- Clean up moduledoc references at [lines 100-180](../../lib/jido/agent_server.ex) that describe the `:idle`/`:running`/`:waiting`/`:success`/`:failure` status vocabulary — that vocabulary was strategy-specific.

### `lib/jido/agent_server/status.ex` — **deleted entirely** (see "Files to delete")

Module + all public helpers gone. See W8 in findings for rationale.

### `lib/jido/agent_server/queries.ex` — **not touched**

Already clean (only builds children reply from `state.children`). No strategy references to audit.

### `lib/jido/agent_server/directive_exec.ex`

- [line 77](../../lib/jido/agent_server/directive_exec.ex): the hardcoded `state.agent.state.__domain__.llm_status` path is resolved in C2, but any reference to `:__strategy__` is removed here.

## Acceptance

- `mix compile --warnings-as-errors` passes
- Grepping `lib/` for `:__strategy__`, `Jido.Agent.Strategy`, `strategy_opts`, `strategy_snapshot`, `strategy_init` returns zero hits
- `Jido.Plugin.FSM` compiles; an agent declaring `plugins: [Jido.Plugin.FSM]` starts and runs a basic transition
- `mix test` — **expect failures** in:
  - `test/jido/agent/strategy_test.exs`, `strategy_fsm_test.exs`, `strategy_state_test.exs` — deleted or rewritten in C8
  - `test/jido/agent_server/strategy_init_test.exs` — deleted in C8
  - `test/examples/fsm/*.exs` — rewritten in C8 against `Jido.Plugin.FSM`

## Out of scope

- Middleware pipeline changes in `agent_server.ex` (→ C4)
- Deleting the legacy callback shims (`on_before_cmd`/`on_after_cmd` remain `@optional_callbacks` in Agent until C4)
- Rewriting strategy tests (→ C8)

## Risks

- FSM semantic preservation: the FSM strategy has subtle behavior around terminal transition detection, history tracking, and status field naming. The port must keep the public observable behavior identical (the 448-line test suite will verify this in C8).
- The old `Direct.run_instruction/3` built `instruction.context` with `:state`, `:agent`, `:agent_server_pid` keys ([direct.ex:83-91](../../lib/jido/agent/strategy/direct.ex)). C0 retires this context-map convention in favor of the explicit `run(signal, slice, opts, ctx)` arg order. Actions in downstream commits already expect the new shape.
- `Jido.Thread.Agent.has_thread?/1` is called from Direct; relocate the call site without changing Thread's own interface.
