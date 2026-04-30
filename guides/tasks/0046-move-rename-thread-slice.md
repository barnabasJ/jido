---
name: Task 0046 — Move and rename the Thread slice to `Jido.Slices.Thread`
description: Lift `lib/jido/thread/` into `lib/jido/slices/thread/`. The slice DSL module becomes `Jido.Slices.Thread` (was `Jido.Thread.Slice`). The data-type struct becomes `Jido.Slices.Thread.State` (was `Jido.Thread`). Supporting types follow: `Jido.Slices.Thread.Entry`, `Jido.Slices.Thread.EntryNormalizer`, `Jido.Slices.Thread.Store`, `Jido.Slices.Thread.Store.Adapters.{InMemory, JournalBacked}`, and `Jido.Slices.Thread.Actions.{Append, Clear, Ensure}`. `Jido.Thread.Agent` is already deleted by [task 0043](0043-delete-misnamed-agent-helpers.md). Mirrors [task 0044](0044-move-rename-memory-slice.md).
---

# Task 0046 — Move and rename the Thread slice to `Jido.Slices.Thread`

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §1, §3.
- Depends on: [task 0043](0043-delete-misnamed-agent-helpers.md), [task 0044](0044-move-rename-memory-slice.md) (rename pattern).
- Blocks: [task 0052](0052-docs-and-cheat-sheets-refresh.md).
- Leaves tree: **green**.

## Context

Same shape as tasks 0044 and 0045. Thread is the **largest** of the
three default slices because it ships with a pluggable store
abstraction:

- `lib/jido/thread.ex` → `Jido.Thread` (data type + functional API).
- `lib/jido/thread/slice.ex` → `Jido.Thread.Slice` (Spark DSL slice).
- `lib/jido/thread/entry.ex` → `Jido.Thread.Entry` (one history entry).
- `lib/jido/thread/entry_normalizer.ex` → `Jido.Thread.EntryNormalizer`.
- `lib/jido/thread/store.ex` → `Jido.Thread.Store` (pluggable store abstraction).
- `lib/jido/thread/store/adapters/{in_memory,journal_backed}.ex` →
  `Jido.Thread.Store.Adapters.{InMemory, JournalBacked}`.
- `lib/jido/thread/actions/{append,clear,ensure}.ex` →
  `Jido.Thread.Actions.{Append, Clear, Ensure}`.

Eight modules to rename, all under one namespace.

## Goal

After this commit:

- `lib/jido/slices/thread/` exists. `lib/jido/thread/` and
  `lib/jido/thread.ex` do not.
- Module renames listed in the table below are applied tree-wide.
- `mix spark.cheat_sheets` regenerated.

## Approach

### File moves

```sh
git mv lib/jido/thread.ex                     lib/jido/slices/thread/state.ex
git mv lib/jido/thread/slice.ex               lib/jido/slices/thread.ex
git mv lib/jido/thread/entry.ex               lib/jido/slices/thread/entry.ex
git mv lib/jido/thread/entry_normalizer.ex    lib/jido/slices/thread/entry_normalizer.ex
git mv lib/jido/thread/store.ex               lib/jido/slices/thread/store.ex
git mv lib/jido/thread/store                  lib/jido/slices/thread/store
git mv lib/jido/thread/actions                lib/jido/slices/thread/actions
rmdir lib/jido/thread
git mv test/jido/thread                       test/jido/slices/thread
```

The `store` directory and `store.ex` file both move; `git mv` on
the directory after the file is the simplest order. (Or move the
top-level files first, then the directories — same end state.)

### Module renames

| Before | After |
|---|---|
| `Jido.Thread` | `Jido.Slices.Thread.State` |
| `Jido.Thread.Slice` | `Jido.Slices.Thread` |
| `Jido.Thread.Entry` | `Jido.Slices.Thread.Entry` |
| `Jido.Thread.EntryNormalizer` | `Jido.Slices.Thread.EntryNormalizer` |
| `Jido.Thread.Store` | `Jido.Slices.Thread.Store` |
| `Jido.Thread.Store.Adapters.InMemory` | `Jido.Slices.Thread.Store.Adapters.InMemory` |
| `Jido.Thread.Store.Adapters.JournalBacked` | `Jido.Slices.Thread.Store.Adapters.JournalBacked` |
| `Jido.Thread.Actions.Append` | `Jido.Slices.Thread.Actions.Append` |
| `Jido.Thread.Actions.Clear` | `Jido.Slices.Thread.Actions.Clear` |
| `Jido.Thread.Actions.Ensure` | `Jido.Slices.Thread.Actions.Ensure` |

### Caller updates

```sh
find lib test guides livebooks documentation \
  \( -name '*.ex' -o -name '*.exs' -o -name '*.md' -o -name '*.livemd' -o -name '*.cheatmd' \) \
  -exec sed -i '' -E '
    s/Jido\.Thread\.Slice/Jido.Slices.Thread/g;
    s/Jido\.Thread\.EntryNormalizer/Jido.Slices.Thread.EntryNormalizer/g;
    s/Jido\.Thread\.Entry\b/Jido.Slices.Thread.Entry/g;
    s/Jido\.Thread\.Store\.Adapters/Jido.Slices.Thread.Store.Adapters/g;
    s/Jido\.Thread\.Store\b/Jido.Slices.Thread.Store/g;
    s/Jido\.Thread\.Actions/Jido.Slices.Thread.Actions/g;
    s/Jido\.Thread\b/Jido.Slices.Thread.State/g
  ' {} +
```

Note `Jido.Thread.Entry\b` and `Jido.Thread.Store\b` use word
boundaries because `EntryNormalizer` and `Store.Adapters` start
with the same prefix. Run the longer matches first.

After bulk: audit `lib/jido/agent/default_slices.ex`, the
`Jido.Persist.Transform` `@behaviour` declaration in the slice
module (mention in the moduledoc), livebooks, and guides.

## Files to modify

### `lib/jido/slices/thread.ex` (was `lib/jido/thread/slice.ex`)

Rename `defmodule Jido.Thread.Slice` to `defmodule Jido.Slices.Thread`.
The `@behaviour Jido.Persist.Transform` block stays. The
`externalize/1` and `reinstate/1` callbacks operate on the data-type
struct — update their pattern matches from `%Jido.Thread{} = thread`
to `%Jido.Slices.Thread.State{} = thread` (or whatever the struct
is at the import boundary). Update aliases and routes.

### `lib/jido/slices/thread/state.ex` (was `lib/jido/thread.ex`)

Rename `defmodule Jido.Thread` to `defmodule Jido.Slices.Thread.State`.
Internal `alias Jido.Thread.Entry` becomes `alias Jido.Slices.Thread.Entry`,
etc. Functional API unchanged.

### `lib/jido/slices/thread/entry.ex`, `entry_normalizer.ex`

Rename module declarations. Update aliases.

### `lib/jido/slices/thread/store.ex` and `store/adapters/*.ex`

Rename module declarations. The pluggable-store abstraction is
otherwise unchanged. Update `@behaviour Jido.Slices.Thread.Store`
declarations in adapter modules.

### `lib/jido/slices/thread/actions/*.ex`

Rename each `Jido.Thread.Actions.*` module to `Jido.Slices.Thread.Actions.*`.
Inside, replace struct references.

### `lib/jido/agent/default_slices.ex`

Replace `Jido.Thread.Slice` reference with `Jido.Slices.Thread` in
both the framework-defaults code and the moduledoc table.

### `test/jido/slices/thread/**` (was `test/jido/thread/**`)

Update aliases and module references throughout the suite, including
the store-adapter integration tests.

### `test/examples/plugins/thread_slice_test.exs`

Update `extensions: [Jido.Thread.Slice]` and any direct
`Jido.Thread.*` usage.

### Other test files

`test/examples/persistence/default_slices_persistence_test.exs`,
`test/jido/integration/hibernate_thaw_test.exs` (already had
`Jido.Thread.Agent` removed in task 0043; this task picks up the
remaining `Jido.Thread*` references), and the journal-backed-adapter
test.

### Persistence-related guides

`guides/storage.md` references the thread store; update.
`guides/migration-spark-dsl.md` updates.

### `documentation/dsls/*.cheatmd`

Regenerated.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean.
- `mix docs` builds without dead-link warnings.
- `mix spark.cheat_sheets` re-run produces no diff (idempotent).
- `git grep -nE 'Jido\.Thread\b'` returns zero hits in `lib/`, `test/`,
  `guides/`, `livebooks/` (excluding `guides/tasks/`, `guides/adr/`).
- `git grep -nE 'Jido\.Thread\.(Slice|Entry|EntryNormalizer|Store|Actions)\b'`
  same.
- `iex -S mix` smoke test: `extensions: [Jido.Slices.Thread]` works,
  `cmd/2` dispatches `Jido.Slices.Thread.Actions.Append`, observed
  state matches expected `%Jido.Slices.Thread.State{}`.
- The journal-backed-adapter test still passes — that path uses the
  store abstraction heavily and is the most likely place to surface
  a missed alias.

## Out of scope

- Anything outside `Jido.Thread.*` namespace.

## Risks

- **Store-adapter behaviour declarations.** Adapter modules declare
  `@behaviour Jido.Thread.Store`. The bulk-rename script handles
  these, but confirm with `mix dialyzer` that the behaviour link
  is intact after the rename.
- **The `Jido.Persist.Transform` callbacks pattern-match on the
  data-type struct.** Confirm pattern matches are updated to the
  new struct module.
- See [task 0044](0044-move-rename-memory-slice.md) Risks for the
  general bulk-rewrite caveats.
