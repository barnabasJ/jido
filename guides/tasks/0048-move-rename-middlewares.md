---
name: Task 0048 — Move and rename built-in middlewares to `Jido.Middlewares.*`
description: Lift the two in-tree middlewares (`Jido.Middleware.Retry`, `Jido.Middleware.Persister`) from `lib/jido/middleware/` into `lib/jido/middlewares/`, renaming the modules to `Jido.Middlewares.{Retry, Persister}`. The framework base `Jido.Middleware` (`lib/jido/middleware.ex`) **stays** — it's the DSL host module, not a registerable middleware. After the moves the `lib/jido/middleware/` directory is removed (empty). Module renames propagate tree-wide.
---

# Task 0048 — Move and rename built-in middlewares to `Jido.Middlewares.*`

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §1.
- Depends on: [task 0044](0044-move-rename-memory-slice.md) (rename pattern).
- Blocks: [task 0052](0052-docs-and-cheat-sheets-refresh.md).
- Leaves tree: **green**.

## Context

Two built-in middlewares ship in `lib/`:

- `lib/jido/middleware/retry.ex` → `Jido.Middleware.Retry` — wraps
  signal handling with exponential-backoff retry.
- `lib/jido/middleware/persister.ex` → `Jido.Middleware.Persister` —
  blocks on thaw/hibernate during lifecycle signals.

[ADR 0025](../adr/0025-extension-directory-layout.md) §1 lifts
built-in extensions under top-level `slices/` / `middlewares/` /
`plugins/` directories so the file tree itself signals "this is a
registerable extension" vs framework infrastructure.

The framework **base** module `Jido.Middleware` at `lib/jido/middleware.ex`
is the DSL host — it does `use Spark.Dsl, default_extensions:
[extensions: [Jido.Dsl.Middleware]]` and defines the behaviour
contract. It is **not** a registerable middleware itself, so it
stays at `lib/jido/middleware.ex`. Same pattern as `Jido.Slice` and
`Jido.Plugin`.

After this task `lib/jido/middleware/` (the directory) is empty and
gets removed. `lib/jido/middleware.ex` (the framework base file)
stays.

## Goal

After this commit:

- `lib/jido/middlewares/retry.ex` defines `Jido.Middlewares.Retry`.
- `lib/jido/middlewares/persister.ex` defines `Jido.Middlewares.Persister`.
- `lib/jido/middleware/` directory removed.
- `lib/jido/middleware.ex` (`Jido.Middleware` framework base) unchanged.
- Every in-tree caller updated.

## Approach

### File moves

```sh
git mv lib/jido/middleware/retry.ex     lib/jido/middlewares/retry.ex
git mv lib/jido/middleware/persister.ex lib/jido/middlewares/persister.ex
rmdir lib/jido/middleware
git mv test/jido/middleware             test/jido/middlewares
```

Note: `lib/jido/middleware.ex` is **not** moved.

### Module renames

| Before | After |
|---|---|
| `Jido.Middleware.Retry` | `Jido.Middlewares.Retry` |
| `Jido.Middleware.Persister` | `Jido.Middlewares.Persister` |

`Jido.Middleware` (the framework base) keeps its name.

### Caller updates

```sh
find lib test guides livebooks documentation \
  \( -name '*.ex' -o -name '*.exs' -o -name '*.md' -o -name '*.livemd' -o -name '*.cheatmd' \) \
  -exec sed -i '' -E '
    s/Jido\.Middleware\.Retry/Jido.Middlewares.Retry/g;
    s/Jido\.Middleware\.Persister/Jido.Middlewares.Persister/g
  ' {} +
```

The patterns are *specific* — they don't match bare `Jido.Middleware`,
so the framework base reference is left alone.

After bulk: audit `lib/jido/agent.ex` moduledoc Quickstart and
`lib/jido/middleware.ex` moduledoc examples. The Persister middleware
is referenced in `Jido.Persist` documentation; confirm those refs.

## Files to modify

### `lib/jido/middlewares/retry.ex` (was `lib/jido/middleware/retry.ex`)

Rename `defmodule Jido.Middleware.Retry` to `defmodule Jido.Middlewares.Retry`.
Internal aliases unchanged unless they mention `Jido.Middleware.*`
peers — `Persister` is the only one.

### `lib/jido/middlewares/persister.ex` (was `lib/jido/middleware/persister.ex`)

Rename `defmodule Jido.Middleware.Persister` to `defmodule Jido.Middlewares.Persister`.

### `test/jido/middlewares/**` (was `test/jido/middleware/**`)

Update aliases and module references throughout.

### `lib/jido/middleware.ex` (the framework base)

The moduledoc references `Jido.Middleware.Retry` and `Jido.Middleware.Persister`
as examples. Update those references (only the ones inside docstrings
or `@moduledoc` examples — the file's own `defmodule` line stays).

### `lib/jido/persist.ex`

The Persister middleware is the runtime consumer of `Jido.Persist`.
Confirm any `@moduledoc` cross-refs update to `Jido.Middlewares.Persister`.

### `lib/jido/dsl/agent/transformers/walk_extensions.ex`

If it pattern-matches on the middleware module names anywhere, update.
(It should be using Spark introspection, not module-name string matches —
verify and only edit if needed.)

### `lib/jido/agent.ex`

The Quickstart example in the moduledoc shows `extensions: [Jido.Middleware.Retry, ...]`.
Update.

### `guides/middleware.md`, `guides/middleware.livemd`

Replace `Jido.Middleware.Retry` and `Jido.Middleware.Persister`
references.

### `guides/agents.md`, `guides/migration-spark-dsl.md`

Same.

### `livebooks/middleware.livemd` (if present)

Update; re-evaluate.

### `documentation/dsls/*.cheatmd`

Regenerated by `mix spark.cheat_sheets`. Commit the diff.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean.
- `mix docs` builds without dead-link warnings.
- `mix spark.cheat_sheets` re-run produces no diff.
- `git grep -nE 'Jido\.Middleware\.(Retry|Persister)\b'` returns zero
  hits in `lib/`, `test/`, `guides/`, `livebooks/` (excluding
  `guides/tasks/`, `guides/adr/`).
- `git grep -nE 'Jido\.Middleware\b'` still returns hits — those are
  references to the framework base module, expected.
- `lib/jido/middleware/` directory does not exist.
- `iex -S mix` smoke test: an agent declares
  `extensions: [Jido.Middlewares.Retry]`, signals are wrapped, retries
  happen on transient failures.

## Out of scope

- Anything outside the two middleware modules. The framework base
  `Jido.Middleware` and its DSL machinery do not move.
- Adding new middlewares.

## Risks

- **The bulk script accidentally rewrites bare `Jido.Middleware`.**
  The patterns above use `\.(Retry|Persister)` so the framework base
  reference is safe. Spot-check one rewrite by hand before committing.
- **A docstring example in `lib/jido/middleware.ex` is now circular.**
  If the moduledoc references `Jido.Middlewares.Retry` as an example,
  it crosses module boundaries — that's fine for docs, but ExDoc
  might complain about a missing module if the rename order is wrong.
  Run `mix docs` after the file moves complete.
- See [task 0044](0044-move-rename-memory-slice.md) Risks.
