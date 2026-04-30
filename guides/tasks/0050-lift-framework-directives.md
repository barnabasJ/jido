---
name: Task 0050 — Lift framework directives to `lib/jido/directives/`; one struct per file
description: Today framework-level directives are scattered: `lib/jido/agent/directive/{cron, cron_cancel, reply}.ex` define three struct modules in their own files, while `lib/jido/agent/directive.ex` defines an *umbrella* plus 9 more directive structs **inlined** inside the same file (`Emit`, `Error`, `Spawn`, `SpawnAgent`, `AdoptChild`, `StopChild`, `Schedule`, `RunInstruction`, `Stop`). Move all 12 to a top-level `lib/jido/directives/` directory, one struct per file, renamed `Jido.Agent.Directive.*` → `Jido.Directives.*`. The umbrella becomes `Jido.Directives` at `lib/jido/directives.ex`, slimmed to typespecs and module-doc. The blast radius is large — every action that emits directives, the AgentServer's directive executor protocol, every cascade callback — but the change is mechanical (namespace s/r). Slice-owned directives (AI ReAct, Pod) **stay** with their slice.
---

# Task 0050 — Lift framework directives to `lib/jido/directives/`

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §2.
- Depends on: [task 0044](0044-move-rename-memory-slice.md) (rename pattern). Best landed after [task 0047](0047-move-rename-ai-react-slice.md) so the AI ReAct directive moves are already done and don't conflict with the umbrella's classification.
- Blocks: [task 0052](0052-docs-and-cheat-sheets-refresh.md).
- Leaves tree: **green**.

## Context

Per [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md),
directives are bare structs that actions return as side-effect
requests. The runtime's `Jido.AgentServer.DirectiveExec` protocol
dispatches on struct type. So directives are pure values; the
"directive vocabulary" is the set of struct modules that ship with
the framework.

Today that vocabulary is awkwardly filed:

- **3 directive struct modules in their own files** under
  `lib/jido/agent/directive/`:
  - `cron.ex` → `Jido.Agent.Directive.Cron`
  - `cron_cancel.ex` → `Jido.Agent.Directive.CronCancel`
  - `reply.ex` → `Jido.Agent.Directive.Reply`
- **9 inlined directive structs** in `lib/jido/agent/directive.ex`
  (the umbrella file): `Emit`, `Error`, `Spawn`, `SpawnAgent`,
  `AdoptChild`, `StopChild`, `Schedule`, `RunInstruction`, `Stop`.

Two problems:

1. **The umbrella file is fat.** It contains the umbrella moduledoc,
   the `@type t` alias, AND 9 inline struct definitions that should
   each be top-level modules with their own file. The split between
   "in its own file" and "inlined in the umbrella" is arbitrary.
2. **The umbrella lives under `agent/`.** Directives are framework-level
   primitives — they're emitted by every action across the framework,
   not just agent-internal — and they belong at a more prominent
   location than buried under `lib/jido/agent/`.

[ADR 0025](../adr/0025-extension-directory-layout.md) §2 lifts them
to top-level `lib/jido/directives/`, one file per directive struct,
renamed under `Jido.Directives.*`.

**Slice-owned directives stay with their slice.** [Task 0047](0047-move-rename-ai-react-slice.md)
already moved AI ReAct directives to `lib/jido/slices/ai_react/directives/`.
Pod's directives (`Jido.Pod.Directive.{StartNode, StopNode}`) stay
under `lib/jido/pod/directive/` because pod is a special agent kind
(see ADR 0025 §1).

## Goal

After this commit:

- `lib/jido/directives.ex` defines `Jido.Directives` — slim umbrella
  with typespec `@type t :: …` aliasing all 12 directive structs and
  module-doc explaining the convention. **No inline struct definitions.**
- `lib/jido/directives/{emit, error, spawn, spawn_agent, adopt_child,
  stop_child, schedule, run_instruction, stop, cron, cron_cancel,
  reply}.ex` each defines one directive struct as `Jido.Directives.<Name>`.
- `lib/jido/agent/directive.ex` and `lib/jido/agent/directive/`
  removed.
- Every action / cascade callback / executor / ack handler that
  emits or matches a framework directive updates to the new module
  name.
- `Jido.Pod.Directive.{StartNode, StopNode}` and
  `Jido.Slices.AiReact.Directives.{LLMCall, ToolExec}` are
  **untouched** — they are slice-scoped, not framework-level.

## Approach

### Extract inline structs from the umbrella

The umbrella file `lib/jido/agent/directive.ex` defines 9 structs
inline using `defmodule __MODULE__.Emit do … end` (or via aliases).
Extract each into its own file at `lib/jido/directives/<snake_case>.ex`.

The extracted file shape, e.g. for `Emit`:

```elixir
defmodule Jido.Directives.Emit do
  @moduledoc """
  Dispatch a signal via `Jido.Signal.Dispatch`.

  …(documentation extracted from the umbrella)
  """

  @enforce_keys [:signal]
  defstruct [:signal, :dispatch]

  @type t :: %__MODULE__{
          signal: Jido.Signal.t(),
          dispatch: Jido.Signal.Dispatch.dispatch_config() | nil
        }

  defimpl Jido.AgentServer.DirectiveExec do
    def exec(%Jido.Directives.Emit{} = d, _signal, _state) do
      # …existing exec body
    end
  end
end
```

**The `defimpl` blocks for `Jido.AgentServer.DirectiveExec`** that
today live in the umbrella (or inline next to each struct) move with
each directive struct into its own file. The protocol `for:` clause
updates to point at the new struct module.

### Move existing per-file directives

```sh
git mv lib/jido/agent/directive/cron.ex        lib/jido/directives/cron.ex
git mv lib/jido/agent/directive/cron_cancel.ex lib/jido/directives/cron_cancel.ex
git mv lib/jido/agent/directive/reply.ex       lib/jido/directives/reply.ex
rmdir lib/jido/agent/directive
```

### Replace the umbrella file

Replace `lib/jido/agent/directive.ex` with `lib/jido/directives.ex`:

```sh
git rm lib/jido/agent/directive.ex
# Then create lib/jido/directives.ex by hand (slim umbrella).
```

The new `lib/jido/directives.ex` is small:

```elixir
defmodule Jido.Directives do
  @moduledoc """
  Framework-level directives — pure side-effect requests an action returns.

  Per ADR 0019, an action returns `{:ok, slice, [directive]}`; a
  directive describes I/O the runtime performs (emit a signal,
  spawn a process, persist, schedule). Directives mutate no state.

  ## Core Directives

  - `Jido.Directives.Emit` — dispatch a signal via `Jido.Signal.Dispatch`.
  - `Jido.Directives.Error` — signal an error.
  - `Jido.Directives.Spawn` — spawn a generic BEAM child process.
  - `Jido.Directives.SpawnAgent` — spawn a child Jido agent with hierarchy tracking.
  - `Jido.Directives.AdoptChild` — attach an orphaned child to current parent.
  - `Jido.Directives.StopChild` — request a tracked child agent to stop.
  - `Jido.Directives.Schedule` — schedule a delayed message.
  - `Jido.Directives.RunInstruction` — execute an instruction at runtime.
  - `Jido.Directives.Stop` — stop the agent process.
  - `Jido.Directives.Cron` — register a cron schedule.
  - `Jido.Directives.CronCancel` — cancel a cron schedule.
  - `Jido.Directives.Reply` — reply to a synchronous call.

  Slice-owned directives live next to their slice
  (e.g. `Jido.Slices.AiReact.Directives.LLMCall`).
  """

  alias Jido.Directives.{
    Emit,
    Error,
    Spawn,
    SpawnAgent,
    AdoptChild,
    StopChild,
    Schedule,
    RunInstruction,
    Stop,
    Cron,
    CronCancel,
    Reply
  }

  @typedoc "Any framework directive struct."
  @type t ::
          Emit.t()
          | Error.t()
          | Spawn.t()
          | SpawnAgent.t()
          | AdoptChild.t()
          | StopChild.t()
          | Schedule.t()
          | RunInstruction.t()
          | Stop.t()
          | Cron.t()
          | CronCancel.t()
          | Reply.t()
end
```

### Caller updates

Every action across the framework, every cascade callback, every
executor, every test that pattern-matches on a directive struct
needs the namespace s/r. Run a tree-wide bulk:

```sh
find lib test guides livebooks documentation \
  \( -name '*.ex' -o -name '*.exs' -o -name '*.md' -o -name '*.livemd' -o -name '*.cheatmd' \) \
  -exec sed -i '' -E '
    s/Jido\.Agent\.Directive\.Emit/Jido.Directives.Emit/g;
    s/Jido\.Agent\.Directive\.Error/Jido.Directives.Error/g;
    s/Jido\.Agent\.Directive\.Spawn\b/Jido.Directives.Spawn/g;
    s/Jido\.Agent\.Directive\.SpawnAgent/Jido.Directives.SpawnAgent/g;
    s/Jido\.Agent\.Directive\.AdoptChild/Jido.Directives.AdoptChild/g;
    s/Jido\.Agent\.Directive\.StopChild/Jido.Directives.StopChild/g;
    s/Jido\.Agent\.Directive\.Schedule/Jido.Directives.Schedule/g;
    s/Jido\.Agent\.Directive\.RunInstruction/Jido.Directives.RunInstruction/g;
    s/Jido\.Agent\.Directive\.Stop\b/Jido.Directives.Stop/g;
    s/Jido\.Agent\.Directive\.Cron\b/Jido.Directives.Cron/g;
    s/Jido\.Agent\.Directive\.CronCancel/Jido.Directives.CronCancel/g;
    s/Jido\.Agent\.Directive\.Reply/Jido.Directives.Reply/g;
    s/Jido\.Agent\.Directive\b/Jido.Directives/g
  ' {} +
```

The `\b` word boundaries on `Spawn`, `Stop`, `Cron` are critical —
without them, `Spawn` rewrites collide with `SpawnAgent`, `Stop`
with `StopChild`, and `Cron` with `CronCancel`. Run the longer-suffix
matches first (the regex order above is intentional).

The bare `Jido.Agent.Directive` rewrite at the end catches the
umbrella references (`alias Jido.Agent.Directive`,
`@type ... :: Jido.Agent.Directive.t()`).

After bulk: audit by hand:

- `lib/jido/agent_server/directive_exec.ex` — protocol definition
  module. The `defprotocol` line stays (the protocol is still
  `Jido.AgentServer.DirectiveExec`); only `@for:` clauses inside
  the moved files change.
- `lib/jido/agent_server/directive_executors.ex` — runtime executor
  switch / case. May pattern-match on struct names.
- `lib/jido/actions/control.ex`, `lib/jido/actions/lifecycle.ex`,
  `lib/jido/actions/scheduling.ex` — built-in actions that emit
  directives.
- Every cascade callback in `lib/jido/agent_server/lifecycle.ex` and
  related (`maybe_track_child_started/2`, `maybe_track_cron_registered/2`,
  etc.) — these match on directive structs.
- All test files that pattern-match on directive structs.

## Files to create

### `lib/jido/directives.ex`

Slim umbrella with typespec + module-doc. See template above.

### `lib/jido/directives/emit.ex`

Extracted from the umbrella's inline `Emit` struct. One module
declaration, struct fields, typespec, and the matching
`defimpl Jido.AgentServer.DirectiveExec` block.

### `lib/jido/directives/error.ex`, `spawn.ex`, `spawn_agent.ex`, `adopt_child.ex`, `stop_child.ex`, `schedule.ex`, `run_instruction.ex`, `stop.ex`

Same shape — extract each from the umbrella.

## Files to move

```sh
git mv lib/jido/agent/directive/cron.ex        lib/jido/directives/cron.ex
git mv lib/jido/agent/directive/cron_cancel.ex lib/jido/directives/cron_cancel.ex
git mv lib/jido/agent/directive/reply.ex       lib/jido/directives/reply.ex
```

Inside each, rename `defmodule Jido.Agent.Directive.Cron` →
`defmodule Jido.Directives.Cron` (and same for the other two).

## Files to delete

- `lib/jido/agent/directive.ex` (replaced by `lib/jido/directives.ex`).
- `lib/jido/agent/directive/` directory (now empty).

## Files to modify (bulk-rewrite + manual audit)

Every file that references `Jido.Agent.Directive` or any of its
children. The bulk-rewrite covers the namespace s/r; the manual
audit confirms semantic correctness. Notably:

- `lib/jido/agent_server/{directive_exec,directive_executors}.ex`.
- `lib/jido/agent_server/lifecycle.ex` (cascade callbacks).
- `lib/jido/actions/{control,lifecycle,scheduling}.ex` (built-in actions).
- `lib/jido/scheduler.ex` (cron directive emission).
- `lib/jido/agent/directive.ex` is deleted; any moduledoc in
  `lib/jido/agent.ex` referencing it must update.
- Every action under `lib/jido/slices/*/actions/` that emits a
  framework directive.
- Test files in `test/jido/agent/`, `test/jido/agent_server/`, and
  example tests.
- `guides/directives.md`, `guides/agents.md`, `guides/migration-spark-dsl.md`,
  livebooks.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean.
- `mix docs` builds without dead-link warnings.
- `mix spark.cheat_sheets` re-run produces no diff.
- `git grep -nE 'Jido\.Agent\.Directive\b'` returns zero hits in
  `lib/`, `test/`, `guides/`, `livebooks/` (excluding `guides/tasks/`,
  `guides/adr/`).
- `lib/jido/agent/directive/` and `lib/jido/agent/directive.ex` do not
  exist.
- `Jido.Pod.Directive.*` references still resolve — pod is unmoved.
- `Jido.Slices.AiReact.Directives.*` references resolve — moved by
  task 0047.
- Smoke test: a complete signal → action → directive → executor flow
  in `iex -S mix` runs end-to-end. Easiest is sending a `jido.agent.cancel`
  signal (which dispatches a Reply directive) and observing the ack.

## Out of scope

- Slice-owned directive moves (already done by [task 0047](0047-move-rename-ai-react-slice.md)
  for AI ReAct).
- Pod directive renames (deliberately not moved per ADR 0025).
- Adding new directive struct fields or behaviour.

## Risks

- **The bulk script's `\b` word boundaries are load-bearing.** A
  bug here cascades: `Spawn` could rewrite into `SpawnAgent`'s prefix
  (or worse). Order matters: the longer-suffix patterns must run
  before the shorter. Spot-check one rewrite in each of `Spawn`,
  `Stop`, `Cron` by hand before committing.
- **Inline-struct extraction loses moduledoc context.** The umbrella
  file's per-struct doc paragraphs need to move into the new files'
  `@moduledoc` blocks. Read the existing umbrella before extracting;
  preserve every doc paragraph.
- **`Jido.AgentServer.DirectiveExec` protocol implementations**
  must move with the structs. Today some are co-located with the
  umbrella's inline structs; they need to move into the extracted
  files as `defimpl` blocks. The compile-time `Protocol.consolidated?`
  check catches missing impls; rerun `mix compile` after each batch.
- **A test pattern-matches on the umbrella struct directly** (e.g.
  `assert %Jido.Agent.Directive{} = ...`). The umbrella has no
  struct after this task; rewrite such tests to match the specific
  directive (`%Jido.Directives.Emit{}`).
- **Blast radius is large.** Every action that emits a directive
  references at least one of these names. Plan the work as one
  sustained editing session rather than piecemeal — bulk-rewrite,
  spot-audit, compile, test.
