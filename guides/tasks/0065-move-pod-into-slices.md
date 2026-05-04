---
name: Task 0065 — Move `Jido.Pod` into `lib/jido/slices/`
description:
  ADR 0025 §"Pod stays" was decided when Pod was a sibling-of-`Jido.Agent` agent
  kind with parallel runtime / DSL machinery. Task 0061 collapsed Pod into a
  single `use Jido.Slice` module that contributes a typed `pod do … end` section
  via `Jido.Pod.Transformers.RegisterContribution`. Post-0061, Pod is
  structurally a slice — it just happens to be the largest one. The "split
  feature tree" objection that justified the exception no longer applies,
  because the post-0061 convention (slice declaration at `lib/jido/slices/X.ex`,
  supporting machinery at `lib/jido/slices/X/`) is exactly the shape Pod already
  has at `lib/jido/pod{.ex,/}`. This task moves the entire pod tree into
  `lib/jido/slices/pod{.ex,/}`, renames `Jido.Pod.*` → `Jido.Slices.Pod.*` (15+
  modules), and removes the ADR-0025 "Pod stays" exception. After this lands
  `lib/jido/pod*` no longer exists; `Jido.Pod` becomes `Jido.Slices.Pod`, the
  slice atom convention `slice :pod, Jido.Slices.Pod` becomes `slice :pod,
  Jido.Slices.Pod` (atom unchanged), and the `pod do … end` host-section keeps
  working because it is a Spark-Extension contribution keyed on the module not
  the file path.
---

# Task 0065 — Move `Jido.Pod` into `lib/jido/slices/`

- Implements: removes the last ADR 0025 §"Pod stays" exception; brings Pod onto
  the same convention as Memory / FSM / Identity / Thread / AiReact.
- Depends on: [task 0061](0061-collapse-pod-into-agent-extension.md)
  (Pod-as-a-slice), [task 0064](0064-classify-and-relocate-pod-bus-plugin.md)
  (BusPlugin lifted out of `lib/jido/pod/` first so this task only handles
  pod-runtime-coupled code).
- Blocks: nothing.
- Leaves tree: **green**.

## Context

ADR 0025 §"Pod stays at `lib/jido/pod/`" justifies the exception with two
claims:

> Pod is a special agent kind whose plugin (`Jido.Pod.Plugin`) and bus plugin
> (`Jido.Pod.BusPlugin`) are tightly coupled to pod runtime, topology, and
> mutation pipelines. Promoting them to `Jido.Plugins.Pod*` would split pod
> across two trees with no win.

Both claims have decayed:

1. **"Pod is a special agent kind."** Task 0061 collapsed Pod into a single
   `use Jido.Slice` + `use Spark.Dsl.Extension` module. There is no
   `Jido.Pod.Plugin` anymore — `lib/jido/pod.ex:109` is `use Jido.Slice`. Pod is
   structurally a slice; calling it a special agent kind is a holdover.
2. **"Promoting them would split pod across two trees."** That objection is
   correct only if some of pod stays at `lib/jido/pod/` and some moves. The task
   here is to move the **entire** subtree, which is the same convention every
   other built-in slice already follows:

   | Slice                 | Declaration                   | Machinery                                                               |
   | --------------------- | ----------------------------- | ----------------------------------------------------------------------- |
   | Memory                | `lib/jido/slices/memory.ex`   | `lib/jido/slices/memory/{state,space,actions,transformers}.ex`          |
   | Thread                | `lib/jido/slices/thread.ex`   | `lib/jido/slices/thread/{state,entry,store,actions,transformers}.ex`    |
   | AiReact               | `lib/jido/slices/ai_react.ex` | `lib/jido/slices/ai_react/{state,actions,directives,...}.ex`            |
   | Pod (today)           | `lib/jido/pod.ex`             | `lib/jido/pod/{actions,directive,mutation,topology,runtime,...}`        |
   | Pod (after this task) | `lib/jido/slices/pod.ex`      | `lib/jido/slices/pod/{actions,directive,mutation,topology,runtime,...}` |

   Pod is bigger than Memory or Thread. Bigger is a quantitative difference, not
   a qualitative one. The convention scales — putting Pod in `lib/jido/slices/`
   does not make the slices/ tree harder to scan because each slice's machinery
   stays under its own subdirectory.

Keeping the exception means a permanent special case in every navigation guide
("slices live in `lib/jido/slices/` _except Pod_"). Removing it makes the rule
universal.

## Goal

After this task:

1. `lib/jido/slices/pod.ex` defines `Jido.Slices.Pod` (was `lib/jido/pod.ex` /
   `Jido.Pod`).
2. `lib/jido/slices/pod/` contains every former neighbour of `lib/jido/pod.ex`:
   `actions/`, `directive/`, `directive_exec.ex`, `info.ex`, `mutable.ex`,
   `mutation/`, `mutation.ex`, `queries.ex`, `runtime.ex`, `topology/`,
   `topology.ex`, `topology_state.ex`, `transformers/`. Same files, same
   relative layout, just rooted under `slices/pod/` instead of `pod/`.
3. Every `Jido.Pod.*` module is renamed `Jido.Slices.Pod.*` — this includes the
   runtime, topology, mutation, queries, transformers, and every action /
   directive under the pod subtree.
4. The slice atom stays `:pod` (it is configured by the host's `slice :pod, …`
   line, not by the slice's module path).
5. The contributed `pod do … end` host section keeps working — it is keyed on
   the slice module, not the file location.
6. ADR 0025 §"Pod stays" exception is removed; the universal rule ("slices live
   in `lib/jido/slices/`, middlewares in `lib/jido/middlewares/`") gets a clean
   statement.
7. Tree compiles clean; full test suite passes.

## Approach

### Estimate

Roughly:

```
lib/jido/pod.ex                       → lib/jido/slices/pod.ex
lib/jido/pod/actions/*.ex             → lib/jido/slices/pod/actions/*.ex
lib/jido/pod/directive/*.ex           → lib/jido/slices/pod/directive/*.ex
lib/jido/pod/directive_exec.ex        → lib/jido/slices/pod/directive_exec.ex
lib/jido/pod/info.ex                  → lib/jido/slices/pod/info.ex
lib/jido/pod/mutable.ex               → lib/jido/slices/pod/mutable.ex
lib/jido/pod/mutation.ex              → lib/jido/slices/pod/mutation.ex
lib/jido/pod/mutation/*.ex            → lib/jido/slices/pod/mutation/*.ex
lib/jido/pod/queries.ex               → lib/jido/slices/pod/queries.ex
lib/jido/pod/runtime.ex               → lib/jido/slices/pod/runtime.ex
lib/jido/pod/topology.ex              → lib/jido/slices/pod/topology.ex
lib/jido/pod/topology/*.ex            → lib/jido/slices/pod/topology/*.ex
lib/jido/pod/topology_state.ex        → lib/jido/slices/pod/topology_state.ex
lib/jido/pod/transformers/*.ex        → lib/jido/slices/pod/transformers/*.ex
test/jido/pod/*                        → test/jido/slices/pod/*
```

Around 30 source + 30 test files. All renames are mechanical.

### Mechanical rewrite

```sh
# moves
git mv lib/jido/pod.ex lib/jido/slices/pod.ex
git mv lib/jido/pod   lib/jido/slices/pod   # (rmdir afterwards if empty parent)
git mv test/jido/pod  test/jido/slices/pod

# module renames — find every Jido.Pod and rewrite to Jido.Slices.Pod
rg -l --type elixir 'Jido\.Pod\b' | xargs sed -i 's/Jido\.Pod\b/Jido.Slices.Pod/g'

# verify nothing in lib/test still references the old namespace
rg -nP "\bJido\.Pod\b" lib/ test/
# expected output: empty
```

The `\b` boundary matters because there are unrelated names like `Jido.PodSpec`
(none in tree at writing) that would otherwise get caught.

### Risks

- **Test fixtures relying on file path strings.** None in tree — checked with
  `rg "lib/jido/pod" test/`.
- **Igniter templates.** `lib/jido/igniter/templates.ex` references `Jido.Pod`
  string-encoded into generated code. Update those literals too.
- **Module attribute strings inside docstrings.** Run `rg -n "Jido\.Pod" lib/`
  after the bulk rewrite and skim what remains; most matches inside `@moduledoc`
  / `@doc` strings will already be correct because they come from the same bulk
  rewrite, but eyeball any doctest blocks.

### ADR 0025 update

In `guides/adr/0025-extension-directory-layout.md`:

- §"Consequences", "Pod stays at `lib/jido/pod/`" bullet (lines ~165–169):
  delete, replaced by a new bullet stating that **every** built-in slice now
  lives at `lib/jido/slices/X.ex` with machinery under `lib/jido/slices/X/` —
  Pod included, no exceptions.
- §"Alternatives considered", "Promote pod plugins to `lib/jido/plugins/pod/`"
  bullet (lines ~209–211): rewrite to reflect the post-0064/0065 reality — Pod
  is a slice, not a plugin; its machinery lives at `lib/jido/slices/pod/`; the
  rejected alternative was promoting it to `lib/jido/plugins/`, which this task
  pre-empts entirely.

ADR 0025 status stays **Accepted / Implementation Complete**; the layout intent
never changed, only the scope of the exception did.

## Acceptance criteria

- [ ] `lib/jido/pod.ex` and `lib/jido/pod/` do not exist after the task.
- [ ] `lib/jido/slices/pod.ex` defines `Jido.Slices.Pod`.
- [ ] Every former `Jido.Pod.*` module is renamed under `Jido.Slices.Pod.*`.
- [ ] `rg -nP "\bJido\.Pod\b" lib/ test/` returns nothing.
- [ ] Audit grep stays clean: every `use Jido.Slice` in `lib/` is under
      `lib/jido/slices/`.
- [ ] ADR 0025 "Pod stays" exception removed.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] `mix test` passes (1935+ tests, 0 failures).
- [ ] One commit, prefixed `refactor(task-0065):`.

## Out of scope

- The slice atom (`:pod`) does not change. The atom is set by the host's
  `slice :pod, …` mount line; it is independent of the module's namespace.
- The `pod do … end` host section keeps its name. It is contributed by
  `Jido.Pod.Transformers.RegisterContribution` (renamed during this task to
  `Jido.Slices.Pod.Transformers.RegisterContribution`), and the section name
  itself (`:pod`) is module-attribute-defined — moving the file does not change
  it.
- External users who alias `Jido.Pod` need to rewrite to `Jido.Slices.Pod`.
  Captured in [task 0067](0067-migration-notes-rename-chain.md).
