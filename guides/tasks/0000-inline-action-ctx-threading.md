# Task 0000 — Inline `jido_action`; unify action signature; ctx threading

- Commit #: 0 of 9
- Implements: foundation for [ADR 0014](../adr/0014-slice-middleware-plugin.md), [ADR 0015](../adr/0015-agent-start-is-signal-driven.md), [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md). Prerequisite for everything else.
- Depends on: —
- Blocks: 0001 (and everything downstream)
- Leaves tree: **green** (existing tests rewritten to new signature)

## Goal

Bring `Jido.Action`, `Jido.Instruction`, and `Jido.Exec` from the external `jido_action` dep into this repo, then change the callback from `run(params, context)` to **`run(signal, slice, opts, ctx)`** — four explicit args. Establish `signal.extensions[:jido_ctx]` as the canonical location for per-signal runtime context (user, trace, tenant) threaded through actions, middleware, and directives. Delete `Jido.Actions.Status.*` (unused convention library).

This commit is the foundation. Everything in C1–C8 assumes the inlined Action surface and the new callback shape.

## Why inline

- `jido_action` (~6K lines core) defines `@callback run(params, context)` — three args folded into two, with `context` conflating runtime identity, slice state, and ambient config. Unclear to readers, impossible to evolve without coordinated cross-repo releases.
- Inlining gives full control over the callback signature and lifecycle without forking or coordinating hex versions.
- The Jido-specific conventions (slice, opts, ctx) are strong enough to own the Action contract.

`jido_signal` (~17K lines) is NOT inlined. `Signal.t()` already has an `extensions: map()` field — we use `signal.extensions[:jido_ctx]` as the ctx carrier and touch nothing in the dep.

## Files to inline (from `jido_action` dep)

Source: the `jido_action` hex package at version 2.2.1. Run `mix deps.get` from the repo root to materialize sources under `deps/jido_action/` (or point at the hex source at `hex.pm/packages/jido_action/2.2.1` if preferred).

### Modules to bring in (preserve module names)

| Source | Destination | Notes |
|---|---|---|
| `jido_action.ex` (Action behaviour, ~687 LoC) | `lib/jido/action.ex` | Callback rewritten (see below) |
| `jido_instruction.ex` (606 LoC) | `lib/jido/instruction.ex` | Shape preserved; new signature plumbed through `Exec.run/1` |
| `jido_action/exec.ex` + subtrees (~1800 LoC) | `lib/jido/exec.ex` + `lib/jido/exec/` | Execution engine — `chain`, `compensation`, `retry`, `async`, `closure`, `telemetry`, `validator`, `supervisors` |
| `jido_action/schema.ex`, `schema/json_schema_bridge.ex` (~459+ LoC) | `lib/jido/action/schema.ex`, `lib/jido/action/schema/json_schema_bridge.ex` | Action schema validation via Zoi |
| `jido_action/error.ex` (570 LoC) | merged into existing `lib/jido/error.ex` | Fold action-specific error types into `Jido.Error` — single framework-wide error surface. Users pattern-match one module, not two. |
| `jido_action/util.ex` (186) | `lib/jido/action/util.ex` | Helper functions |
| `jido_action/runtime.ex` (94) | `lib/jido/action/runtime.ex` | Runtime dispatch helpers |
| `jido_action/tool.ex` (208) | `lib/jido/action/tool.ex` | Tool integration (LangChain-style) |

### Modules to skip

- `jido_tools/*` (3,283 LoC) — reference implementations (Arithmetic, Files, Req, Workflow, Lua, Basic, ActionPlan). Not framework infrastructure. External users who relied on these keep using `jido_action` via hex directly — but as they're a dep of `jido`, they'd need to copy them into their own apps. Acceptable trade-off.
- `jido_plan.ex` (538 LoC) — multi-action orchestration. **Drop** — verified zero `Jido.Plan` / `jido_plan` references in `lib/`. Users of `Jido.Plan` who want orchestration write their own composition or wait for a future plan/workflow-focused PR.
- `jido_action/application.ex` (14 LoC) — dep-level OTP application. Merge into `Jido.Application` if any supervision is needed.
- `mix/tasks/jido_action.*` — generators. Jido has its own via `lib/mix/tasks/jido.gen.*`.

### Drop the dep

- Remove `{:jido_action, "~> 2.2"}` from `mix.exs`.
- Run `mix deps.unlock --unused` after.

## The new Action callback

```elixir
defmodule Jido.Action do
  @moduledoc """
  Actions reduce a slice of agent state in response to a signal.

  Shape: `(signal, slice, opts, ctx) -> {:ok, new_slice, directives} | {:error, reason}`

  - `signal`: the `Jido.Signal.t()` that triggered the action. Action type is `signal.type`;
    payload is `signal.data`. Per-signal runtime ctx is at `signal.extensions[:jido_ctx]`
    (already extracted and passed as the `ctx` arg).
  - `slice`: the current value of `agent.state[path]` where `path` is the action's declared path.
    Actions own their slice's next-value — return the full new slice, not a patch.
  - `opts`: static options attached at route registration. From `{"work.start", {MyAction, %{max_retries: 3}}}`,
    `opts = %{max_retries: 3}`. Default `%{}`.
  - `ctx`: per-signal runtime context (user, trace, tenant, parent, partition, agent_id).
    Propagates to emitted signals' `extensions[:jido_ctx]` by default; middleware can
    augment or strip before forwarding.
  - Returns:
    - `{:ok, new_slice}` — slice replaces with `new_slice`, no directives
    - `{:ok, new_slice, directives}` — plus effect directives
    - `{:error, reason}` — action failed; reason propagates as `%Directive.Error{}`
  """

  @callback run(
              signal :: Jido.Signal.t(),
              slice :: term(),
              opts :: map(),
              ctx :: map()
            ) ::
              {:ok, new_slice :: term()} |
              {:ok, new_slice :: term(), directives :: [struct()]} |
              {:error, reason :: term()}

  # Optional validation hooks (carried over from jido_action, same shape):
  @callback on_before_validate_params(params :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_validate_params(params :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_before_validate_output(output :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_validate_output(output :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_run(result :: {:ok, map()} | {:error, any()}) ::
              {:ok, term()} | {:error, any()}

  # `on_error/3` is DROPPED (was: (error, params, context) → {:ok|:error, _}).
  # With `run/4`, actions handle errors inline in the callback body via plain
  # `case`/`with` expressions; a separate hook adds ceremony without capability.

  @optional_callbacks [
    on_before_validate_params: 1,
    on_after_validate_params: 1,
    on_before_validate_output: 1,
    on_after_validate_output: 1,
    on_after_run: 1
  ]

  defmacro __using__(opts) do
    # The existing jido_action `__using__/1` is ported here with:
    # - declarative schema, name, description, category, vsn, tags, output_schema
    # - compile-time validation
    # - default implementations of the optional hooks
    # - **required: path: option** for actions that reduce a slice
    # - `path` accessor function
    # - generate `run/4` default that raises "not implemented"
    # - generate Tool adapter (unchanged)
    ...
  end
end
```

`use Jido.Action` takes a **required `path:`** option. Every action declares the slice it operates on. If an action emits directives without reading state, it still declares `path:` (it still sees the slice in `run/4`; it just doesn't change it — returns the unchanged slice). Uniform signature.

`Jido.Agent.ScopedAction` is **deleted**. Its job (declare which slice an action owns) folds into plain `Jido.Action`.

## Ctx threading — the universal principle

**Origin**: a caller seeds ctx by putting a map at `signal.extensions[:jido_ctx]` when constructing the signal:

```elixir
signal = Jido.Signal.new!("work.start", %{task_id: "t-1"},
  extensions: %{jido_ctx: %{current_user: user_id, trace_id: tid}})
```

Helpers:
```elixir
Jido.Signal.put_ctx(signal, key, value) :: Signal.t()
Jido.Signal.get_ctx(signal, key, default \\ nil) :: term()
```

Alternatively, `AgentServer.cast_and_await/4` and `AgentServer.subscribe/4` accept `ctx:` in opts — merged into the signal's ctx at the boundary.

**Flow**:

```
caller                                                 agent
   |                                                     |
   | cast_and_await(pid, signal, selector,               |
   |                ctx: %{current_user: u})             |
   |---------------------------------------------------->|
   |                                                     |
   |         signal.extensions[:jido_ctx] = %{current_user: u}
   |                                                     |
   |           AgentServer extracts ctx from signal      |
   |           adds agent-level runtime identity:        |
   |             %{current_user: u, agent_id, partition, |
   |               parent, orphaned_from}                |
   |                                                     |
   |           middleware chain receives (sig, ctx, opts, next)
   |              - may augment ctx (e.g., add :tenant)  |
   |              - may strip ctx (e.g., redact :secrets)|
   |                                                     |
   |           action receives (sig, slice, opts, ctx)   |
   |              - reads ctx.current_user for authZ     |
   |              - returns {:ok, new_slice, dirs}       |
   |                                                     |
   |           directive exec:                           |
   |              - emitted signals inherit ctx via     |
   |                signal.extensions[:jido_ctx]         |
   |              - exec itself sees ctx (for authZ,     |
   |                audit, tracing)                      |
```

**In `%AgentServer.State{}`**: no ctx field. ctx is per-signal, not per-agent. Agent-level runtime identity (`partition`, `parent`, `orphaned_from`, `agent_id`) is read FROM state INTO ctx at signal receipt time.

## Surfaces receiving ctx

### Action callback (4 args)

```elixir
def run(signal, slice, opts, ctx) do
  # access signal.type, signal.data, ctx.current_user, opts.max_retries, slice fields
  ...
end
```

### Middleware callback (4 args)

```elixir
# lib/jido/middleware.ex
@callback on_signal(
            signal :: Signal.t(),
            ctx :: map(),
            opts :: map(),
            next :: (Signal.t(), map() -> {map(), [struct()]})
          ) :: {map(), [struct()]}
```

Note: middleware's `ctx` IS the thing it threads. It can augment before `next.(sig, augmented_ctx)` and strip before returning. The returned map is the resulting ctx passed to the outer wrap.

### Directive executor

```elixir
# lib/jido/agent_server/directive_exec.ex
@callback exec(
            directive :: struct(),
            signal :: Signal.t(),
            ctx :: map(),
            state :: AgentServer.State.t()
          ) :: {:ok, AgentServer.State.t()} | {:stop, reason :: term(), AgentServer.State.t()}
```

When a directive emits a new signal (`%Directive.Emit{}`), ctx propagates:
```elixir
emitted_signal = Jido.Signal.put_ctx(target_signal, :jido_ctx, ctx)
```

## Files to delete

### `lib/jido/actions/status.ex` — **delete entirely**

`Jido.Actions.Status.SetStatus`, `.MarkCompleted`, `.MarkFailed`, `.MarkWorking`, `.MarkIdle` — all unused as actual signal_routes in-repo. Convention moves to migration guide.

### `lib/jido/agent/scoped_action.ex` — **delete entirely**

Folded into `Jido.Action` with required `path:`.

## Files to modify

- **`mix.exs`**: remove `{:jido_action, "~> 2.2"}` dep; add any transitive deps jido_action pulled in that we now need directly (e.g., if it pulled `:zoi` transitively and we rely on that — usually it's a direct dep already).
- **`lib/jido/signal.ex`** (if it exists in this repo — otherwise elsewhere): add `put_ctx/3` and `get_ctx/3` helpers around `signal.extensions[:jido_ctx]`. If `Jido.Signal` is only the external dep, create `lib/jido/signal_ctx.ex` with these helpers.
- **Every in-repo action module that uses `use Jido.Agent.ScopedAction` or `use Jido.Action`**: migrate to new `run/4` signature. Audit list:
  - `lib/jido/pod/actions/*.ex` (Mutate, QueryNodes, QueryTopology)
  - `lib/jido/pod/bus_plugin/auto_subscribe_child.ex`, `auto_unsubscribe_child.ex`
  - `lib/jido/actions/control.ex`, `lib/jido/actions/lifecycle.ex`, `lib/jido/actions/scheduling.ex`
  - Any FSM actions (they move in C3)
- **`lib/jido/agent/strategy/direct.ex`**: `run_instruction/3` and related — the merge branch goes away. This file is deleted in C3 anyway; in this commit, simplify the logic that prepares ctx and slice for `run/4`.

## Tests to rewrite

- `test/jido/actions/status_test.exs` — **delete** (matches source deletion).
- Every test that directly calls `.run(params, %{})` on an action module must update to `.run(signal, slice, opts, ctx)`:
  - `test/jido/actions/scheduling_test.exs` (if exists)
  - `test/jido/actions/control_test.exs` (if exists)
  - `test/jido/actions/lifecycle_test.exs` (if exists)
  - `test/jido/pod/actions/*.exs`
- Add `test/jido/action_test.exs` — unit tests for the new behaviour: signature validation, schema validation flow, default implementations.
- Add `test/jido/signal_ctx_test.exs` — tests for `put_ctx/3`, `get_ctx/3`, signal propagation via `extensions[:jido_ctx]`.

## Migration cheat sheet (internal)

| Before | After |
|---|---|
| `def run(params, context) do ... end` | `def run(signal, slice, opts, ctx) do ... end` |
| `%{state: slice}` inside `context` | `slice` is the 2nd arg |
| `params` (merged signal payload + static opts) | `signal.data` for payload; `opts` for static route opts |
| `context[:jido_instance]` | `ctx.jido_instance` (or wherever AgentServer seeds it) |
| `use Jido.Agent.ScopedAction, state_key: :foo` | `use Jido.Action, path: :foo` |
| `use Jido.Action` (unscoped) | `use Jido.Action, path: <slice>` — now always declares path |
| Return `{:ok, %{status: :x}}` (partial → merged) | Return `{:ok, %{slice | status: :x}}` (full slice) |

## Acceptance

- `mix compile --warnings-as-errors` passes
- `mix test` **green** — failing tests rewritten; `status_test.exs` deleted
- `mix.exs` no longer depends on `:jido_action`
- `mix deps.tree` shows `jido_action` absent
- `Jido.Action`, `Jido.Instruction`, `Jido.Exec` compile under `lib/jido/`
- An action using new `run/4` shape works end-to-end with a plain `cmd/2` call (no AgentServer)
- A signal constructed with `Jido.Signal.put_ctx(sig, :trace_id, t)` delivers the trace_id to the action's `ctx.trace_id` arg
- An emitted signal from the action inherits `ctx` automatically

## Out of scope

- Slice / Middleware / Plugin abstractions (→ C1)
- `path:` requirement on `use Jido.Agent` (→ C2)
- Middleware pipeline in AgentServer (→ C4)
- Removing `:__domain__` magic atoms from `agent.state` (→ C2)
- FSM port (→ C3)

## Risks

- **Action callback is a public behaviour** — every downstream (including in-repo plugins' actions in C5) must migrate. Scope is real: audit shows ~dozens of action modules. Mechanical rewrites, but numerous.
- **Signal ctx field namespace collision** — `signal.extensions[:jido_ctx]` must not collide with any existing usage of `extensions` in the codebase. Grep before picking the key; reserve it in the `Jido.Signal` docs.
- **`jido_action` transitive deps** — jido_action may pull `nimble_options`, `zoi`, `telemetry` transitively. After removing the dep, add any that our inlined code needs directly to `mix.exs`.
- **`jido_plan.ex` disposition** — if Jido agents use `Jido.Plan` internally, we keep it; otherwise drop. Audit `grep -r Jido.Plan lib/` before committing.
- **Test action modules** — many test fixtures define local action modules inline. All need migration. Consider a codemod script.
- **`Jido.Actions.Status.*` deletion impact on docs/ADRs** — ADR 0010, 0016 reference these. Update the ADR text accordingly (ADR 0016's "No changes to `Jido.Actions.Status`" sentence becomes "No `Jido.Actions.Status` shipped; convention migrated to user code via the migration guide.").
