---
name: Task 0047 — Move and rename the AI ReAct slice to `Jido.Slices.AiReact`
description: Lift the ReAct slice and its companions out of `lib/jido/ai/` into `lib/jido/slices/ai_react/`. The slice DSL module becomes `Jido.Slices.AiReact` (was `Jido.AI.ReAct`). Companions move under it: `Jido.Slices.AiReact.Turn` (was `Jido.AI.Turn`), `Jido.Slices.AiReact.ToolAdapter` (was `Jido.AI.ToolAdapter`), `Jido.Slices.AiReact.Actions.*` (was `Jido.AI.Actions.*`), and `Jido.Slices.AiReact.Directives.{LLMCall, ToolExec}` (was `Jido.AI.Directive.*` — directory renamed to plural for consistency with the new top-level `lib/jido/directives/`). The `Jido.AI` facade (`lib/jido/ai.ex`) **stays put** as a thin entry point per [ADR 0025](../adr/0025-extension-directory-layout.md); only its internal aliases and docstring example update.
---

# Task 0047 — Move and rename the AI ReAct slice to `Jido.Slices.AiReact`

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §1, §2 (slice-owned directives), §3 (data-type/slice split — though ReAct has no separate data type, the slice owns its own state schema).
- Depends on: [task 0044](0044-move-rename-memory-slice.md) (rename pattern), and ideally lands after tasks 0045/0046 so the slice rename batch is contiguous.
- Blocks: [task 0050](0050-lift-framework-directives.md) (Phase D directives task references the AI ReAct directive moves), [task 0052](0052-docs-and-cheat-sheets-refresh.md).
- Leaves tree: **green**.

## Context

`Jido.AI.ReAct` is the LLM-agent slice — implements the synchronous
ReAct loop over `req_llm`. Today it lives at `lib/jido/ai/re_act.ex`,
sharing the `Jido.AI.*` namespace with:

- `lib/jido/ai.ex` → `Jido.AI` (a thin facade exposing
  `Jido.AI.ask/3` and similar).
- `lib/jido/ai/turn.ex` → `Jido.AI.Turn` (normalised projection of
  a `ReqLLM.Response`).
- `lib/jido/ai/tool_adapter.ex` → `Jido.AI.ToolAdapter` (converts
  `Jido.Action` modules to `ReqLLM.Tool` structs).
- `lib/jido/ai/actions/{ask,failed,llm_turn,tool_result}.ex` →
  `Jido.AI.Actions.*`.
- `lib/jido/ai/directive/{llm_call,tool_exec}.ex` →
  `Jido.AI.Directive.{LLMCall, ToolExec}`.

Five of those six things are slice internals. Only `Jido.AI` is a
user-facing facade — it's the API users call (`Jido.AI.ask(agent, ...)`).
[ADR 0025](../adr/0025-extension-directory-layout.md) keeps that
facade where it is and lifts the rest into `lib/jido/slices/ai_react/`.

This task also folds in **two ADR-0025 consistencies**:

1. **The slice-owned directive directory becomes plural**:
   `lib/jido/slices/ai_react/directives/`. This matches the new
   top-level `lib/jido/directives/` introduced by
   [task 0050](0050-lift-framework-directives.md). Singular `directive/`
   was the historical pod/AI convention; the plural form is the
   ADR-0025-canonical shape.
2. **The slice path encodes "AI ReAct" as one word**: `:ai_react`,
   `Jido.Slices.AiReact`. Underscore in file path; PascalCase in
   module name. This avoids an awkward `Jido.Slices.AI.ReAct` where
   `AI` is a separate namespace level for one slice.

## Goal

After this commit:

- `lib/jido/slices/ai_react/` exists. `lib/jido/ai/re_act.ex` and
  the companions in `lib/jido/ai/{turn.ex, tool_adapter.ex, actions/, directive/}`
  do not.
- Module renames listed in the table below applied tree-wide.
- `Jido.AI` facade still works — `Jido.AI.ask/3` returns the same
  shape; only its internal aliases change.
- `mix spark.cheat_sheets` regenerated.

## Approach

### File moves

```sh
git mv lib/jido/ai/re_act.ex            lib/jido/slices/ai_react.ex
git mv lib/jido/ai/turn.ex              lib/jido/slices/ai_react/turn.ex
git mv lib/jido/ai/tool_adapter.ex      lib/jido/slices/ai_react/tool_adapter.ex
git mv lib/jido/ai/actions              lib/jido/slices/ai_react/actions
git mv lib/jido/ai/directive            lib/jido/slices/ai_react/directives
rmdir lib/jido/ai
git mv test/jido/ai                     test/jido/slices/ai_react
```

The `lib/jido/ai/directive` → `lib/jido/slices/ai_react/directives`
rename is the **plural** consistency change. After the move,
`lib/jido/ai/` is empty (everything moved out except `lib/jido/ai.ex`,
which is one level up). `rmdir lib/jido/ai` succeeds.

`lib/jido/ai.ex` (`Jido.AI` facade) stays exactly where it is.

### Module renames

| Before | After |
|---|---|
| `Jido.AI.ReAct` | `Jido.Slices.AiReact` |
| `Jido.AI.Turn` | `Jido.Slices.AiReact.Turn` |
| `Jido.AI.ToolAdapter` | `Jido.Slices.AiReact.ToolAdapter` |
| `Jido.AI.Actions.Ask` | `Jido.Slices.AiReact.Actions.Ask` |
| `Jido.AI.Actions.Failed` | `Jido.Slices.AiReact.Actions.Failed` |
| `Jido.AI.Actions.LLMTurn` | `Jido.Slices.AiReact.Actions.LLMTurn` |
| `Jido.AI.Actions.ToolResult` | `Jido.Slices.AiReact.Actions.ToolResult` |
| `Jido.AI.Directive.LLMCall` | `Jido.Slices.AiReact.Directives.LLMCall` |
| `Jido.AI.Directive.ToolExec` | `Jido.Slices.AiReact.Directives.ToolExec` |

`Jido.AI` (the facade) keeps its module name.

### Caller updates

```sh
find lib test guides livebooks documentation \
  \( -name '*.ex' -o -name '*.exs' -o -name '*.md' -o -name '*.livemd' -o -name '*.cheatmd' \) \
  -exec sed -i '' -E '
    s/Jido\.AI\.ReAct/Jido.Slices.AiReact/g;
    s/Jido\.AI\.Turn/Jido.Slices.AiReact.Turn/g;
    s/Jido\.AI\.ToolAdapter/Jido.Slices.AiReact.ToolAdapter/g;
    s/Jido\.AI\.Actions/Jido.Slices.AiReact.Actions/g;
    s/Jido\.AI\.Directive\.LLMCall/Jido.Slices.AiReact.Directives.LLMCall/g;
    s/Jido\.AI\.Directive\.ToolExec/Jido.Slices.AiReact.Directives.ToolExec/g
  ' {} +
```

**Do not** include a bare `Jido.AI` rewrite — the facade keeps its
name. The targeted patterns above leave `Jido.AI.ask/3`,
`Jido.AI.ask_sync/3`, etc. untouched.

After bulk: audit `lib/jido/ai.ex` (the facade) to confirm its
internal aliases now reference the renamed modules. Audit
`livebooks/llm-agent.livemd` (re-evaluate the cells as part of
acceptance).

## Files to modify

### `lib/jido/slices/ai_react.ex` (was `lib/jido/ai/re_act.ex`)

Rename `defmodule Jido.AI.ReAct` to `defmodule Jido.Slices.AiReact`.
Update internal aliases and `signal_routes do … end` references.
The `use Jido.Slice.Extension, host_section: :react` line stays —
the `:react` host section name is what users see in their agent
DSL (`react do … end`), unrelated to the module rename. (Optionally
consider renaming the host section to `:ai_react` for consistency,
but that is a public-API change for users with `react do … end`
blocks; defer to a separate ADR if desired.)

### `lib/jido/slices/ai_react/turn.ex`, `tool_adapter.ex`

Rename module declarations and internal aliases.

### `lib/jido/slices/ai_react/actions/*.ex`

Rename `Jido.AI.Actions.*` → `Jido.Slices.AiReact.Actions.*`. Internal
references to the directive structs update from
`%Jido.AI.Directive.LLMCall{}` to `%Jido.Slices.AiReact.Directives.LLMCall{}`.

### `lib/jido/slices/ai_react/directives/*.ex`

Rename `Jido.AI.Directive.LLMCall` → `Jido.Slices.AiReact.Directives.LLMCall`.
Same for `ToolExec`. The `Jido.AgentServer.DirectiveExec` protocol
implementations live in those struct files (today as `defimpl`
blocks); update the `for:` clause to point at the new struct module.

### `lib/jido/ai.ex` (the facade — stays put)

The `defmodule Jido.AI` declaration is unchanged. Internal aliases
update:

```diff
-  alias Jido.AI.ReAct
-  alias Jido.AI.Actions.Ask
+  alias Jido.Slices.AiReact
+  alias Jido.Slices.AiReact.Actions.Ask
```

The moduledoc Quickstart example (currently around line 30 — uses
`use Jido.Agent, extensions: [Jido.AI.ReAct]`) updates to
`extensions: [Jido.Slices.AiReact]`.

### `test/jido/slices/ai_react/**`

Update aliases and module references.

### Test integration / livebook callsites

`livebooks/llm-agent.livemd` is the integration smoke test for the
ReAct slice. Re-evaluate every cell after the rename; the model
spec input + agent definition + signal flow all need to pass.

### `guides/llm-agent.livemd`, `guides/agents.md`, `guides/migration-spark-dsl.md`

Replace ReAct references in code blocks.

### `documentation/dsls/*.cheatmd`

Regenerated by `mix spark.cheat_sheets`. Commit the diff.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean. The ReAct integration test
  (`:e2e`-tagged) hits LM Studio locally; this task is the most
  likely place to break that path. Run it explicitly.
- `mix docs` builds without dead-link warnings.
- `mix spark.cheat_sheets` re-run produces no diff (idempotent).
- `git grep -nE 'Jido\.AI\.(ReAct|Turn|ToolAdapter|Actions|Directive)\b'`
  returns zero hits in `lib/`, `test/`, `guides/`, `livebooks/`
  (excluding `guides/tasks/`, `guides/adr/`).
- `Jido.AI.ask/3` and `Jido.AI.ask_sync/3` still respond — the
  facade is unchanged. A smoke `iex` test that calls them confirms.
- `livebooks/llm-agent.livemd` evaluates cleanly end-to-end with
  the configurable model input.

## Out of scope

- Renaming the `:react` host section of the slice (the typed-block
  name users see). That's a public-API change distinct from the
  module rename; defer to a separate ADR if desired.
- Extracting `Jido.AI` and the ReAct slice into a separate package
  to make `req_llm` optional. ADR 0025 §5 mentions this as a future
  ADR; not in this chain.

## Risks

- **The directive subdirectory rename (`directive/` → `directives/`)
  is a directory move, not just a module rename.** Make sure the
  `git mv` happens before the bulk-rename script — otherwise `sed`
  rewrites the alias path in module source while the file still
  lives at the singular path, and the compile breaks.
- **The host_section name `:react` does not match the new module
  name `Jido.Slices.AiReact`.** Users will see `react do … end` in
  their agent DSL but `extensions: [Jido.Slices.AiReact]` in the
  options — they look like two different things until you read the
  ADR. The migration guide refresh in [task 0052](0052-docs-and-cheat-sheets-refresh.md)
  needs a paragraph explaining this. The alternative — renaming the
  host section to `:ai_react` — is a separate user-facing API change
  and should be its own ADR.
- See [task 0044](0044-move-rename-memory-slice.md) Risks for
  general bulk-rewrite caveats.
