---
name: Task 0049 — Move and rename the FSM plugin to `Jido.Plugins.FSM`
description: Lift the FSM plugin out of `lib/jido/plugin/fsm.ex` and `lib/jido/plugin/fsm/` into `lib/jido/plugins/fsm.ex` and `lib/jido/plugins/fsm/`. Modules rename `Jido.Plugin.FSM` → `Jido.Plugins.FSM` and `Jido.Plugin.FSM.Transition` → `Jido.Plugins.FSM.Transition`. Framework plugin internals (`lib/jido/plugin/{config, instance, requirements, routes, schedules, spec}.ex`) **stay** under `lib/jido/plugin/` — they are runtime-side helpers, not user-facing plugins. Pod plugins (`Jido.Pod.Plugin`, `Jido.Pod.BusPlugin`) **stay** under `lib/jido/pod/` per [ADR 0025](../adr/0025-extension-directory-layout.md) — pod is its own agent kind.
---

# Task 0049 — Move and rename the FSM plugin to `Jido.Plugins.FSM`

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §1.
- Depends on: [task 0044](0044-move-rename-memory-slice.md) (rename pattern).
- Blocks: [task 0052](0052-docs-and-cheat-sheets-refresh.md).
- Leaves tree: **green**.

## Context

The FSM plugin (`Jido.Plugin.FSM`) is the only generic, user-mountable
plugin that currently ships in tree. It lives at:

- `lib/jido/plugin/fsm.ex` → `Jido.Plugin.FSM` — the plugin module
  (`use Jido.Plugin`).
- `lib/jido/plugin/fsm/transition.ex` → `Jido.Plugin.FSM.Transition`
  — the action that runs a state transition.

The rest of `lib/jido/plugin/` is **framework infrastructure** —
`config.ex`, `instance.ex`, `requirements.ex`, `routes.ex`,
`schedules.ex`, `spec.ex` — these are runtime-side helpers consumed
by the framework, not user-facing plugins. Same role as `lib/jido/slice/`
relative to `lib/jido/slices/`. They stay where they are.

Pod's plugins (`lib/jido/pod/plugin.ex` defining `Jido.Pod.Plugin`
and `lib/jido/pod/bus_plugin.ex` defining `Jido.Pod.BusPlugin`)
**stay** under `lib/jido/pod/`. Per
[ADR 0025](../adr/0025-extension-directory-layout.md) §1, pod is a
special agent kind whose plugins are tightly coupled to its runtime.
Promoting them to `lib/jido/plugins/pod*` would split pod across two
trees with no win.

So this task moves exactly two files and renames two modules.

## Goal

After this commit:

- `lib/jido/plugins/fsm.ex` defines `Jido.Plugins.FSM`.
- `lib/jido/plugins/fsm/transition.ex` defines `Jido.Plugins.FSM.Transition`.
- `lib/jido/plugin/fsm.ex` and `lib/jido/plugin/fsm/` removed.
- `lib/jido/plugin/{config, instance, requirements, routes, schedules, spec}.ex`
  still in place, unchanged.
- `lib/jido/plugin.ex` (framework base, `Jido.Plugin` host module) unchanged.
- Every in-tree caller updated.

## Approach

### File moves

```sh
git mv lib/jido/plugin/fsm.ex            lib/jido/plugins/fsm.ex
git mv lib/jido/plugin/fsm/transition.ex lib/jido/plugins/fsm/transition.ex
rmdir lib/jido/plugin/fsm
git mv test/jido/plugin/fsm              test/jido/plugins/fsm
```

(If there's a `test/jido/plugin/fsm_test.exs` directly rather than
a directory, adjust accordingly.)

### Module renames

| Before | After |
|---|---|
| `Jido.Plugin.FSM` | `Jido.Plugins.FSM` |
| `Jido.Plugin.FSM.Transition` | `Jido.Plugins.FSM.Transition` |

`Jido.Plugin` (framework base) and `Jido.Plugin.{Config, Instance, ...}`
(framework internals) keep their names.

`Jido.Pod.Plugin` and `Jido.Pod.BusPlugin` keep their names.

### Caller updates

```sh
find lib test guides livebooks documentation \
  \( -name '*.ex' -o -name '*.exs' -o -name '*.md' -o -name '*.livemd' -o -name '*.cheatmd' \) \
  -exec sed -i '' -E '
    s/Jido\.Plugin\.FSM\.Transition/Jido.Plugins.FSM.Transition/g;
    s/Jido\.Plugin\.FSM\b/Jido.Plugins.FSM/g
  ' {} +
```

Patterns are specific — they leave `Jido.Plugin`, `Jido.Plugin.Config`,
`Jido.Plugin.Instance`, etc. untouched.

After bulk: audit `lib/jido/plugin.ex` moduledoc (it likely references
`Jido.Plugin.FSM` as the canonical example), and the FSM-plugin
documentation under `guides/`.

## Files to modify

### `lib/jido/plugins/fsm.ex` (was `lib/jido/plugin/fsm.ex`)

Rename `defmodule Jido.Plugin.FSM` to `defmodule Jido.Plugins.FSM`.
Update internal aliases to the new `Transition` module name. The
`use Jido.Plugin` line stays (the framework base name is unchanged).

### `lib/jido/plugins/fsm/transition.ex` (was `lib/jido/plugin/fsm/transition.ex`)

Rename `defmodule Jido.Plugin.FSM.Transition` to `defmodule Jido.Plugins.FSM.Transition`.

### `test/jido/plugins/fsm/**`

Update aliases and module references.

### `lib/jido/plugin.ex` (framework base, stays put)

The moduledoc likely references `Jido.Plugin.FSM` as the canonical
example. Update those moduledoc references to `Jido.Plugins.FSM`.
The `defmodule Jido.Plugin` line stays.

### `lib/jido/agent.ex`

The Quickstart example in the moduledoc may show
`extensions: [Jido.Plugin.FSM, ...]`. Update.

### `guides/plugins.md`, `guides/plugins.livemd`, `guides/your-first-plugin.md`

Replace `Jido.Plugin.FSM` and `Jido.Plugin.FSM.Transition` references.

### `guides/agents.md`, `guides/migration-spark-dsl.md`

Same.

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
- `mix spark.cheat_sheets` re-run produces no diff.
- `git grep -nE 'Jido\.Plugin\.FSM\b'` returns zero hits in `lib/`,
  `test/`, `guides/`, `livebooks/` (excluding `guides/tasks/`,
  `guides/adr/`).
- `git grep -nE 'Jido\.Plugin\b'` still returns hits — those are the
  framework base, expected.
- `git grep -nE 'Jido\.Pod\.(Plugin|BusPlugin)\b'` still returns hits
  — those are pod plugins, intentionally not moved, expected.
- `lib/jido/plugin/fsm/` and `lib/jido/plugin/fsm.ex` do not exist.
- `iex -S mix` smoke test: an agent declares
  `extensions: [Jido.Plugins.FSM]`, declares the FSM block, transitions
  fire as expected.

## Out of scope

- Pod plugin renames (deliberate per ADR 0025).
- Framework plugin-internals renames (`Jido.Plugin.{Config, Instance,
  Requirements, Routes, Schedules, Spec}`).
- Adding new plugins.

## Risks

- **The bulk script accidentally rewrites `Jido.Plugin.Config` etc.**
  The pattern uses `\.FSM\b` so framework internals are safe.
  Spot-check one rewrite by hand.
- **A user has the FSM plugin's moduledoc cross-linked.** The rename
  changes the doc URL fragment. ExDoc handles this via the canonical
  module name, but external links may break.
- See [task 0044](0044-move-rename-memory-slice.md) Risks.
