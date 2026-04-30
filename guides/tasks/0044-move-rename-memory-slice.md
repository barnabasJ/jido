---
name: Task 0044 — Move and rename the Memory slice to `Jido.Slices.Memory`
description: Lift `lib/jido/memory/` into `lib/jido/slices/memory/` and rename the modules so directory structure encodes architectural role. The slice DSL module becomes `Jido.Slices.Memory` (was `Jido.Memory.Slice` — drop redundant suffix because the namespace already carries it). The data-type struct becomes `Jido.Slices.Memory.State` (was `Jido.Memory` — split the struct/type role from the namespace-prefix role). Supporting types and actions follow: `Jido.Slices.Memory.Space`, `Jido.Slices.Memory.Actions.*`. All in-tree callers update in lockstep — `lib/jido/agent/default_slices.ex`, every example test, every guide reference. Run `mix spark.cheat_sheets` to regenerate the DSL reference cross-refs. No behaviour change; pure rename + move. Per the "NO LEGACY ADAPTERS" rule, no module aliases, no `@deprecated` shims.
---

# Task 0044 — Move and rename the Memory slice to `Jido.Slices.Memory`

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §1, §3.
- Depends on: [task 0043](0043-delete-misnamed-agent-helpers.md) (deletes `Jido.Memory.Agent` so it does not need renaming alongside the rest of the namespace).
- Blocks: [task 0045](0045-move-rename-identity-slice.md), [task 0046](0046-move-rename-thread-slice.md), [task 0047](0047-move-rename-ai-react-slice.md), [task 0052](0052-docs-and-cheat-sheets-refresh.md).
- Leaves tree: **green**.

## Context

The Memory slice today lives in `lib/jido/memory/` with three roles
mashed under one namespace:

- `lib/jido/memory.ex` defines `Jido.Memory` — the struct + functional
  API for a memory value.
- `lib/jido/memory/slice.ex` defines `Jido.Memory.Slice` — the Spark
  DSL slice declaration (the module users put in `extensions: [...]`).
- `lib/jido/memory/space.ex` defines `Jido.Memory.Space` — supporting
  struct.
- `lib/jido/memory/actions/*.ex` defines `Jido.Memory.Actions.*` — the
  eight slice-owned actions.

Two issues: (1) the directory tree does not signal that this is a
**built-in extension** as opposed to framework infrastructure, and
(2) the namespace `Jido.Memory` is doing double duty — it is both
the data type (`%Jido.Memory{}`) *and* the namespace prefix for
`Memory.Slice`, `Memory.Space`, `Memory.Actions`.

[ADR 0025](../adr/0025-extension-directory-layout.md) settles this
by lifting the slice into `lib/jido/slices/memory/` and splitting
the two roles: `Jido.Slices.Memory` becomes the slice DSL module
(the new entry point users register), `Jido.Slices.Memory.State`
becomes the struct stored at `agent.state[:memory]`. The supporting
types and actions live under the same namespace.

## Goal

After this commit:

- `lib/jido/slices/memory/` exists. `lib/jido/memory/` and
  `lib/jido/memory.ex` do not.
- `Jido.Slices.Memory` is the slice DSL module (was `Jido.Memory.Slice`).
- `Jido.Slices.Memory.State` is the data-type struct (was `Jido.Memory`).
- `Jido.Slices.Memory.Space` is the supporting struct (was `Jido.Memory.Space`).
- `Jido.Slices.Memory.Actions.*` are the eight slice-owned actions.
- Every in-tree caller is updated.
- `mix spark.cheat_sheets` regenerated; the diff is committed.

`Jido.Memory.Agent` is **already deleted** by [task 0043](0043-delete-misnamed-agent-helpers.md);
this task does not need to handle it.

## Approach

This is a mechanical rename + move. Do it in one commit; the diff
is large but uniform.

### File moves

```sh
git mv lib/jido/memory.ex                 lib/jido/slices/memory/state.ex
git mv lib/jido/memory/slice.ex           lib/jido/slices/memory.ex
git mv lib/jido/memory/space.ex           lib/jido/slices/memory/space.ex
git mv lib/jido/memory/actions            lib/jido/slices/memory/actions
rmdir lib/jido/memory
git mv test/jido/memory                   test/jido/slices/memory
```

Note the data-type module ends up at `lib/jido/slices/memory/state.ex`
(under the slice's subdir) and the slice DSL ends up at
`lib/jido/slices/memory.ex` (the slice itself, at the top level of
the slice dir). This matches the convention in
[ADR 0025](../adr/0025-extension-directory-layout.md): the slice
file is the entry point, supporting types nest under it.

### Module renames

Inside the moved files, rename the module declarations:

| Before | After |
|---|---|
| `Jido.Memory` | `Jido.Slices.Memory.State` |
| `Jido.Memory.Slice` | `Jido.Slices.Memory` |
| `Jido.Memory.Space` | `Jido.Slices.Memory.Space` |
| `Jido.Memory.Actions.Append` | `Jido.Slices.Memory.Actions.Append` |
| `Jido.Memory.Actions.AppendToSpace` | `Jido.Slices.Memory.Actions.AppendToSpace` |
| `Jido.Memory.Actions.Delete` | `Jido.Slices.Memory.Actions.Delete` |
| `Jido.Memory.Actions.DeleteFromSpace` | `Jido.Slices.Memory.Actions.DeleteFromSpace` |
| `Jido.Memory.Actions.DeleteSpace` | `Jido.Slices.Memory.Actions.DeleteSpace` |
| `Jido.Memory.Actions.Ensure` | `Jido.Slices.Memory.Actions.Ensure` |
| `Jido.Memory.Actions.EnsureSpace` | `Jido.Slices.Memory.Actions.EnsureSpace` |
| `Jido.Memory.Actions.PutInSpace` | `Jido.Slices.Memory.Actions.PutInSpace` |
| `Jido.Memory.Actions.PutSpace` | `Jido.Slices.Memory.Actions.PutSpace` |
| `Jido.Memory.Actions.UpdateSpace` | `Jido.Slices.Memory.Actions.UpdateSpace` |

(Confirm the action list against the `signal_routes do … end` block
in the slice; that is the canonical set.)

Inside the slice module itself (now `lib/jido/slices/memory.ex`),
update every `route` line to point at the renamed action module:

```elixir
signal_routes do
  route "jido.memory.ensure", Jido.Slices.Memory.Actions.Ensure
  # ...
end
```

The `slice do … end` block stays the same shape; only the `schema`
reference (currently `schema Memory.schema()`) updates to
`schema State.schema()` after a corresponding alias change inside
the file.

### Caller updates

Run a project-wide rename across `lib/`, `test/`, `guides/`,
`livebooks/`, and `documentation/`. The simplest reliable shape:

```sh
# data-type module
find lib test guides livebooks documentation \
  \( -name '*.ex' -o -name '*.exs' -o -name '*.md' -o -name '*.livemd' -o -name '*.cheatmd' \) \
  -exec sed -i '' -E '
    s/Jido\.Memory\.Slice/Jido.Slices.Memory/g;
    s/Jido\.Memory\.Actions/Jido.Slices.Memory.Actions/g;
    s/Jido\.Memory\.Space/Jido.Slices.Memory.Space/g;
    s/Jido\.Memory\b/Jido.Slices.Memory.State/g
  ' {} +
```

Order matters: replace the longer-suffix names *first*
(`Jido.Memory.Slice`, `Jido.Memory.Actions`, `Jido.Memory.Space`)
and then the bare `Jido.Memory` last with `\b` word-boundary so it
doesn't double-rewrite the longer matches.

After the bulk rewrite, audit:

- `lib/jido/agent/default_slices.ex` — the framework default-slices
  list. Before: `[Jido.Thread.Slice, Jido.Identity.Slice, Jido.Memory.Slice]`.
  After: `[Jido.Thread.Slice, Jido.Identity.Slice, Jido.Slices.Memory]`
  (Thread and Identity rename in subsequent tasks).
- `lib/jido/ai.ex` and `lib/jido/ai/re_act.ex` — moduledoc examples
  may reference `Jido.Memory.Slice`. Confirm replaced.
- `lib/jido/agent.ex` — moduledoc Quickstart. Confirm replaced.
- `livebooks/memory.livemd` (if it exists) and `livebooks/llm-agent.livemd`
  — confirm replaced.
- `guides/migration-spark-dsl.md` — confirm replaced (already had
  the example agent name fix in [task 0043](0043-delete-misnamed-agent-helpers.md)).

### Cheat sheets

```sh
mix spark.cheat_sheets
```

Commit the resulting diff in `documentation/dsls/jido-slice.cheatmd`
and any sibling pages that cross-reference Memory module names.

## Files to modify

### `lib/jido/slices/memory.ex` (was `lib/jido/memory/slice.ex`)

Rename `defmodule Jido.Memory.Slice` to `defmodule Jido.Slices.Memory`.
Update the `alias Jido.Memory` and `alias Jido.Memory.Actions` lines
inside the file to alias the renamed modules. Update every
`signal_routes do route "...", ActionModule` to point at the new
action module names.

The last line of the file — `use Jido.Slice.Extension, host_section: :memory`
— stays. The `host_section: :memory` is the typed-block name that
host agents see (`memory do … end`), unrelated to the module rename.

### `lib/jido/slices/memory/state.ex` (was `lib/jido/memory.ex`)

Rename `defmodule Jido.Memory` to `defmodule Jido.Slices.Memory.State`.
Internal `alias Jido.Memory.Space` becomes `alias Jido.Slices.Memory.Space`.
The struct shape and functional API are unchanged.

### `lib/jido/slices/memory/space.ex` (was `lib/jido/memory/space.ex`)

Rename `defmodule Jido.Memory.Space` to `defmodule Jido.Slices.Memory.Space`.
No other change.

### `lib/jido/slices/memory/actions/*.ex` (was `lib/jido/memory/actions/*.ex`)

Rename each `defmodule Jido.Memory.Actions.X` to `defmodule
Jido.Slices.Memory.Actions.X`. Inside each, update `alias`es and
struct references to the renamed types (`%Jido.Slices.Memory.State{}`,
`%Jido.Slices.Memory.Space{}`).

### `lib/jido/agent/default_slices.ex`

Update the framework defaults list and the moduledoc example.

### `test/jido/slices/memory/**` (was `test/jido/memory/**`)

Update every `alias` and module reference. Test setup blocks already
went through the [task 0043](0043-delete-misnamed-agent-helpers.md)
rewrite; this task only renames the modules they reference.

### `test/examples/plugins/memory_slice_test.exs`

Update `extensions: [Jido.Memory.Slice]` → `extensions: [Jido.Slices.Memory]`.
Same for action references.

### `test/examples/persistence/default_slices_persistence_test.exs`

Update `Jido.Memory.Slice`, `Jido.Memory`, `Jido.Memory.Space` references.

### Other test files referencing `Jido.Memory*`

A grep before the bulk replace will surface all of them. Confirm
zero hits remain after.

### `guides/agents.md`, `guides/slices.md`, `guides/storage.md`

Replace `Jido.Memory.Slice`, `Jido.Memory`, `Jido.Memory.Space`
references. Verify code blocks compile when copy-pasted.

### `guides/migration-spark-dsl.md`

The "Why we're migrating" / "One agent module migration" examples
reference `Jido.Memory*`. Update for the new names.

### `livebooks/*.livemd`

`livebooks/llm-agent.livemd` references the slice list and may
reference `Jido.Memory.Slice`. Update; re-evaluate the livebook
end-to-end as part of acceptance.

### `documentation/dsls/*.cheatmd`

Regenerated by `mix spark.cheat_sheets`. Commit the diff verbatim.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean.
- `mix docs` builds without dead-link warnings.
- `mix spark.cheat_sheets` re-run produces no diff (idempotent).
- `git grep -nE 'Jido\.Memory\b'` returns zero hits in `lib/`, `test/`,
  `guides/`, `livebooks/` (excluding `guides/tasks/`, `guides/adr/`,
  and any commit-message fixtures — those are historical records).
- `git grep -nE 'Jido\.Memory\.(Slice|Space|Actions)\b'` returns zero
  hits with the same exclusions.
- An `iex -S mix` session can construct a `MyAgent` with
  `extensions: [Jido.Slices.Memory]`, dispatch
  `MyAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})`,
  and observe `agent.state[:memory]` populated as a
  `%Jido.Slices.Memory.State{}`.

## Out of scope

- Renaming `Jido.Identity.*`, `Jido.Thread.*`, or `Jido.AI.ReAct`.
  Tasks 0045–0047.
- Renaming middlewares or plugins. Tasks 0048–0049.
- Lifting framework directives. Task 0050.
- `Jido.AI` (`lib/jido/ai.ex`) facade — stays put per ADR 0025.

## Risks

- **`sed -i ''` substitution order misbehaves.** Apply the longer-suffix
  rewrites first so the bare `Jido.Memory` substitution does not
  double-process. The `\b` word boundary is critical; without it,
  the script rewrites `Jido.Memory.Slice` → `Jido.Slices.Memory.State.Slice`.
  Test-run the script on a copy of one file before committing.
- **`mix spark.cheat_sheets` output has cross-task drift.** Tasks
  0045–0047 will further change the cheat sheet contents. Consider
  whether to land the cheat-sheet regen here or defer to
  [task 0052](0052-docs-and-cheat-sheets-refresh.md). Recommendation:
  regen here for confidence the move did not break the DSL definitions;
  task 0052 does the final regen for stable output.
- **An external user has `alias Jido.Memory`.** They get a
  `Jido.Memory is undefined` error and need to update their alias.
  The migration guide gains a row for the rename in
  [task 0052](0052-docs-and-cheat-sheets-refresh.md).
