---
name: Task 0027 — Refresh user-facing guides round 2 (retired Strategy, tagged-tuple cmd/2, Pod.mutate shape, result_signal_type rename, missing directives)
description: Task 0018 swept the docs for ADR 0019 / StateOp removal but didn't catch the tagged-tuple cmd/2 shape (ADR 0018), retired Strategy (ADR 0011), the ADR 0017 Pod.mutate return-shape change, the result_action → result_signal_type rename (task 0015), or the missing Reply/SpawnManagedAgent rows in the directive table. Seven user-facing guides still ship broken examples. Fix them.
---

# Task 0027 — Refresh user-facing guides round 2

- Implements: documentation cleanup follow-up to [task 0018](0018-refresh-user-guides-for-adr-0019.md). No production code changes.
- Depends on: nothing.
- Blocks: nothing.
- Leaves tree: green (docs-only).

## Context

[Task 0018](0018-refresh-user-guides-for-adr-0019.md) cleaned every `Jido.Agent.StateOp` reference and the StateOp narrative across the user-facing guides. A full audit of the same guides against ADRs 0011, 0017, 0018, and task 0015 turns up nine more broken examples that 0018 didn't touch:

- **Strategy (retired by [ADR 0011](../adr/0011-retire-strategy-plugins-are-control-flow.md))** still appears as a v2 surface in `agents.md`, `signals.md`, `runtime.md`, `migration.md`. The module doesn't exist in `lib/`; every example fails to compile.
- **`cmd/2` return shape ([ADR 0018](../adr/0018-tagged-tuple-return-shape.md))** still shows the pre-tagged-tuple `{agent, directives}` shape in `agents.md`, `actions.md`, `runtime.md`. The current return is `{:ok, agent, directives} | {:error, reason}`.
- **`Pod.mutate/3` return shape ([ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md))** still shows `{:ok, report}` in `pods.md` — should be `{:ok, %{mutation_id: id, queued: true}}` or use `Pod.mutate_and_wait/3` for a completion report.
- **`RunInstruction` `result_action` → `result_signal_type` (task 0015 / [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md))** still shows the old field name and "routes the result back through cmd/2" prose in `directives.md` and `runtime.md`. Dispatch is now via `signal_routes` to a handler action.
- **Directive table** in `directives.md` is missing `Reply` and `SpawnManagedAgent`. (The same gap on the lib/ side is covered by [task 0026](0026-jido-agent-directive-internal-consistency.md); this task mirrors the fix in the guide.)

Every one of these examples either fails to compile or silently does the wrong thing.

## What to change

### `guides/agents.md`

- Line 23: drop `strategy: Jido.Agent.Strategy.Direct,    # Default`. There is no strategy option anymore. Replace the surrounding example with the current `path:` + `plugins:` shape.
- Lines 37–63: rewrite every `cmd/2` example as `{:ok, agent, directives} = MyAgent.cmd(...)` per ADR 0018. Show an `{:error, reason}` branch at least once.

### `guides/actions.md`

- Lines 277–287: fix the three `cmd/2` examples to the tagged-tuple shape.

### `guides/directives.md`

- Lines 37–51: extend the directive table with rows for `Reply` and `SpawnManagedAgent`. The full list should be 13 rows.
- Line 81: `result_action: :fsm_instruction_result` → `result_signal_type: "myapp.fsm.instruction.replied"`. Show the matching `signal_routes/1` entry in the same example.
- Around line 103: rewrite the prose. Strategies don't exist; the directive emits a result signal that routes via `signal_routes` to a handler action (per [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) §1).

### `guides/runtime.md`

- Lines 50–56: rewrite the "Signal Processing Flow" diagram. Drop "strategy/agent/plugin routes" → "agent + slice + plugin routes". Drop `→ {agent, directives}` → `→ {:ok, agent, directives}`. Rewrite the `RunInstruction` footnote to show the result signal routing through `signal_routes`.
- Line 64: drop "strategy" from the routing prose.

### `guides/signals.md`

- Lines 113–128: delete the "Strategy Signal Routes" section, or rewrite as a Plugin example using `use Jido.Plugin, path: ...` with `signal_routes/1`. Current text references `use Jido.Agent.Strategy`, which doesn't exist.

### `guides/pods.md`

- Lines 100–122 and 296–310: change `{:ok, report} = Jido.Pod.mutate(...)` to either:
  - `{:ok, %{mutation_id: id, queued: true}} = Jido.Pod.mutate(...)` if demonstrating async cast, or
  - `{:ok, report} = Jido.Pod.mutate_and_wait(...)` if the example wants the completion report.

  Pick one per example based on what the surrounding prose is teaching.

### `guides/migration.md`

- Lines 121, 469, 474: drop `strategy: Jido.Strategy.Direct` / `Jido.Strategy.FSM`. The migration text already (correctly) says ADR 0014 retires strategies (line 587) — the early sections need to match.
- The "Strategy Pattern" subsection (lines 464–477) should be rewritten as a "Plugin replaces Strategy" example pointing at `Jido.Plugin.FSM` for the FSM case.

## Acceptance criteria

- Every code block in the seven affected files compiles against current jido and runs as documented.
- `mix docs` builds clean.
- `grep -nE "strategy: Jido\.(Agent\.)?Strategy\." guides/` returns no hits in `.md` or `.livemd` files (excluding `guides/adr/` and `guides/review-findings-*` retrospectives).
- `grep -n "{agent, directives} = " guides/*.md` returns no hits.
- `grep -n "result_action:" guides/*.md` returns no hits (excluding `guides/tasks/0015-*` which discusses the rename).
- The directive table in `guides/directives.md` lists 13 rows.

## Out of scope

- Livebook `Process.sleep` removal — that's [task 0019](0019-remove-process-sleep-from-livebooks.md) and is its own scoped sweep.
- Internal `lib/jido/agent/directive.ex` moduledoc/alias/@type fixes — that's [task 0026](0026-jido-agent-directive-internal-consistency.md).
