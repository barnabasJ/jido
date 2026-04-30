---
name: Task 0045 — Move and rename the Identity slice to `Jido.Slices.Identity`
description: Lift `lib/jido/identity/` into `lib/jido/slices/identity/`. The slice DSL module becomes `Jido.Slices.Identity` (was `Jido.Identity.Slice`). The data-type struct becomes `Jido.Slices.Identity.State` (was `Jido.Identity`). Actions follow: `Jido.Slices.Identity.Actions.*`. `Jido.Identity.Agent` and `Jido.Identity.Profile` are already deleted by [task 0043](0043-delete-misnamed-agent-helpers.md), so this task only touches the slice + data type + actions. All in-tree callers update in lockstep — `lib/jido/agent/default_slices.ex`, every example test, every guide reference. Mirrors [task 0044](0044-move-rename-memory-slice.md) for Memory.
---

# Task 0045 — Move and rename the Identity slice to `Jido.Slices.Identity`

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §1, §3.
- Depends on: [task 0043](0043-delete-misnamed-agent-helpers.md) (deletes `Jido.Identity.Agent` and `Jido.Identity.Profile`), [task 0044](0044-move-rename-memory-slice.md) (establishes the rename pattern; the bulk-rewrite script template is the same shape).
- Blocks: [task 0052](0052-docs-and-cheat-sheets-refresh.md).
- Leaves tree: **green**.

## Context

Same shape as [task 0044](0044-move-rename-memory-slice.md): the
`Jido.Identity.*` namespace is doing double duty (data type +
namespace prefix), and the slice file is mixed in with framework
infrastructure under `lib/jido/`. This task lifts it under
`lib/jido/slices/identity/` and splits the namespace.

Identity is **simpler** than Memory: there is no `Space` analog
(identity has a single profile field instead of a flexible
container map). Three actions instead of eight. The work is
otherwise mechanical-equivalent.

The four files this task touches today:

- `lib/jido/identity.ex` → `Jido.Identity` (data type + functional API).
- `lib/jido/identity/slice.ex` → `Jido.Identity.Slice` (Spark DSL slice).
- `lib/jido/identity/actions/{ensure,evolve,update_profile}.ex` →
  `Jido.Identity.Actions.{Ensure, Evolve, UpdateProfile}`.

`lib/jido/identity/agent.ex` and `lib/jido/identity/profile.ex` are
**deleted** by [task 0043](0043-delete-misnamed-agent-helpers.md);
this task does not touch them.

## Goal

After this commit:

- `lib/jido/slices/identity/` exists. `lib/jido/identity/` and
  `lib/jido/identity.ex` do not.
- `Jido.Slices.Identity` is the slice DSL module.
- `Jido.Slices.Identity.State` is the data-type struct.
- `Jido.Slices.Identity.Actions.{Ensure, Evolve, UpdateProfile}`.
- Every in-tree caller updated.
- `mix spark.cheat_sheets` regenerated.

## Approach

### File moves

```sh
git mv lib/jido/identity.ex             lib/jido/slices/identity/state.ex
git mv lib/jido/identity/slice.ex       lib/jido/slices/identity.ex
git mv lib/jido/identity/actions        lib/jido/slices/identity/actions
rmdir lib/jido/identity
git mv test/jido/identity               test/jido/slices/identity
```

### Module renames

| Before | After |
|---|---|
| `Jido.Identity` | `Jido.Slices.Identity.State` |
| `Jido.Identity.Slice` | `Jido.Slices.Identity` |
| `Jido.Identity.Actions.Ensure` | `Jido.Slices.Identity.Actions.Ensure` |
| `Jido.Identity.Actions.Evolve` | `Jido.Slices.Identity.Actions.Evolve` |
| `Jido.Identity.Actions.UpdateProfile` | `Jido.Slices.Identity.Actions.UpdateProfile` |

### Caller updates

```sh
find lib test guides livebooks documentation \
  \( -name '*.ex' -o -name '*.exs' -o -name '*.md' -o -name '*.livemd' -o -name '*.cheatmd' \) \
  -exec sed -i '' -E '
    s/Jido\.Identity\.Slice/Jido.Slices.Identity/g;
    s/Jido\.Identity\.Actions/Jido.Slices.Identity.Actions/g;
    s/Jido\.Identity\b/Jido.Slices.Identity.State/g
  ' {} +
```

Order matters: longer-suffix rewrites first.

After bulk: audit `lib/jido/agent/default_slices.ex` (the framework
defaults list), `lib/jido/agent.ex` moduledoc Quickstart, livebooks,
and guides.

## Files to modify

### `lib/jido/slices/identity.ex` (was `lib/jido/identity/slice.ex`)

Rename `defmodule Jido.Identity.Slice` to `defmodule Jido.Slices.Identity`.
Update `alias Jido.Identity` and `alias Jido.Identity.Actions` lines.
Update the `signal_routes do … end` block to point at the renamed
action modules. The trailing `use Jido.Slice.Extension, host_section: :identity`
line stays — `host_section: :identity` is the host's typed-block
name, unrelated to the module rename.

### `lib/jido/slices/identity/state.ex` (was `lib/jido/identity.ex`)

Rename `defmodule Jido.Identity` to `defmodule Jido.Slices.Identity.State`.
Functional API unchanged.

### `lib/jido/slices/identity/actions/*.ex`

Rename each module declaration to `Jido.Slices.Identity.Actions.*`.
Inside each action, replace struct references and `alias`es.

### `lib/jido/agent/default_slices.ex`

Replace `Jido.Identity.Slice` reference with `Jido.Slices.Identity`
in both the framework-defaults code and the moduledoc table.

### `test/jido/slices/identity/**` (was `test/jido/identity/**`)

Update `alias`es and module references.

### `test/examples/plugins/identity_slice_test.exs`

Update `extensions: [Jido.Identity.Slice]` → `extensions: [Jido.Slices.Identity]`,
plus the `CustomIdentitySlice` example agent's references and any
direct `Jido.Identity.*` usage in setup.

### Other test files

`test/examples/persistence/default_slices_persistence_test.exs` and
any other test that references `Jido.Identity*`.

### `guides/agents.md`, `guides/slices.md`, `guides/migration-spark-dsl.md`

Replace identity references in code blocks.

### `livebooks/*.livemd`

Replace identity references; re-evaluate the livebooks as part of
acceptance.

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
- `mix spark.cheat_sheets` re-run produces no diff (idempotent).
- `git grep -nE 'Jido\.Identity\b'` returns zero hits in `lib/`, `test/`,
  `guides/`, `livebooks/` (excluding `guides/tasks/`, `guides/adr/`).
- `git grep -nE 'Jido\.Identity\.(Slice|Actions)\b'` same.
- `iex -S mix` smoke test: agent with `extensions: [Jido.Slices.Identity]`,
  `cmd/2` dispatches `Jido.Slices.Identity.Actions.Ensure`, observes
  `%Jido.Slices.Identity.State{}` at `agent.state[:identity]`.

## Out of scope

- Anything outside the `Jido.Identity.*` namespace. Tasks 0046–0050.

## Risks

- See [task 0044](0044-move-rename-memory-slice.md) Risks. Same
  shape — bulk-rewrite ordering, cheat-sheet drift across tasks,
  external `alias` breakage.
