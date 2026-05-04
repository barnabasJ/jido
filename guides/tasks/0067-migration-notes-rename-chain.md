---
name: Task 0067 — Migration notes for the 0044–0066 rename chain
description:
  The directory-layout reorg started by ADR 0025 and executed across tasks
  0044–0066 produced ~25 module renames, most of them hard breaks for external
  users (`Jido.Memory.Slice` → `Jido.Slices.Memory`, `Jido.Plugin.FSM` →
  `Jido.Slices.FSM`, `Jido.Identity.Slice` → `Jido.Slices.Identity`,
  `Jido.Thread.Slice` → `Jido.Slices.Thread`, `Jido.AI.ReAct` →
  `Jido.Slices.AiReact`, `Jido.Middleware.Retry` → `Jido.Middlewares.Retry`,
  `Jido.Middleware.Persister` → `Jido.Middlewares.Persister`, framework
  directives lifted to `Jido.Directives.*`, `Jido.Pod.BusPlugin` →
  `Jido.Slices.ChildBus`, `Jido.Pod` → `Jido.Slices.Pod`, plus the `Jido.Plugin`
  keep-or-deprecate decision from task 0066). `guides/migration-spark-dsl.md`
  already has section "## One agent module migration" / "## One slice module
  migration" / "## One plugin module migration" sections from the ADR-0023 work,
  with one inline "Update — task 0053" callout, but the rename chain is not
  represented anywhere as a single before-after table. This task adds a
  consolidated "## ADR 0025 directory layout — rename map" section near the top
  of the migration guide that lists every rename in one table, plus a per-rename
  one-paragraph rationale for the cases that aren't pure namespace adjustments
  (Plugin → Slice reclassifications, Pod's full subtree move, the BusPlugin
  reclass). Output is purely documentation; no code changes.
---

# Task 0067 — Migration notes for the 0044–0066 rename chain

- Implements: docs gap left by tasks 0044–0066. Each individual task lands green
  and updates the _guides it touches_, but no single document inventories the
  whole rename chain so external users can grep their code in one pass.
- Depends on: [task 0064](0064-classify-and-relocate-pod-bus-plugin.md),
  [task 0065](0065-move-pod-into-slices.md),
  [task 0066](0066-decide-jido-plugin-abstraction.md) (the migration recipe for
  `Jido.Plugin` differs depending on whether it's kept or deprecated).
- Blocks: nothing. This task can also be split into per-rename additions, one
  per individual task above, if the order they land in dictates.
- Leaves tree: **green** (docs only).

## Context

`guides/migration-spark-dsl.md` was written for ADR 0023 (Spark DSL migration).
It documents:

- The flat-keyword-list → sectioned-DSL rewrite for agent modules.
- One example each for slice / plugin migration.
- The `extensions: […]` three modes.
- Common pitfalls.

What it does **not** document:

- The post-ADR-0025 module-name renames that came in tasks 0044–0050.
- The FSM reclassification (b5a1c49: `Jido.Plugins.FSM` → `Jido.Slices.FSM`).
- The BusPlugin reclassification + rename (task 0064: `Jido.Pod.BusPlugin` →
  `Jido.Slices.ChildBus`).
- The Pod move (task 0065: `Jido.Pod.*` → `Jido.Slices.Pod.*`).
- The Plugin abstraction decision (task 0066: keep or deprecate).

External users coming back to a Jido upgrade after a few months see ~25 modules
renamed and have to piece the recipe together from individual task docs and
ADR 0025. That's a poor upgrade experience.

## Goal

After this task:

1. `guides/migration-spark-dsl.md` has a new section near the top — suggested
   heading `## ADR 0025 directory layout — rename map` — placed between the "Why
   we're migrating" section and "One agent module migration", containing:
   - A short prose intro (1 paragraph) explaining the layout reorg.
   - A single before/after rename table covering every module rename.
   - A `Find/Replace` block of `sed` or `rg --replace` commands that
     mechanically apply the bulk of the rewrite.
2. Each rename row points to the task that landed it, so a reader can dig in.
3. Reclassifications (Plugin → Slice) get one-line rationale in the table or in
   a small follow-up note, because the user's port is not a pure
   `s/before/after/g` — they may want to keep `@behaviour Jido.Middleware` if
   they actually use the middleware half (FSM and BusPlugin did not, but
   external users might).
4. The Pod move row links to task 0065 and notes that the change is the
   namespace only (slice atom `:pod` and host section `pod do … end` are
   unchanged).
5. The `Jido.Plugin` row's content depends on task 0066's decision:
   - If KEEP: row says "no rename — `Jido.Plugin` continues to work".
   - If DEPRECATE Phase A: row says `@deprecated`, points at the
     reclassification recipe, links to the example fixture (if added).
   - If DEPRECATE Phase B is also done by this point: row says "removed, port to
     `use Jido.Slice` + `@behaviour Jido.Middleware`", with the full recipe
     inline.

## Approach

### Suggested rename table shape

```markdown
| Before                                    | After                                       | Task           | Notes                                                                          |
| ----------------------------------------- | ------------------------------------------- | -------------- | ------------------------------------------------------------------------------ |
| `Jido.Memory.Slice`                       | `Jido.Slices.Memory`                        | [task 0044](…) | namespace only                                                                 |
| `Jido.Memory.Slice.State`                 | `Jido.Slices.Memory.State`                  | [task 0044](…) | namespace only                                                                 |
| `Jido.Memory.Slice.Space`                 | `Jido.Slices.Memory.Space`                  | [task 0044](…) | namespace only                                                                 |
| `Jido.Identity.Slice`                     | `Jido.Slices.Identity`                      | [task 0045](…) | namespace only                                                                 |
| `Jido.Thread.Slice`                       | `Jido.Slices.Thread`                        | [task 0046](…) | namespace only                                                                 |
| `Jido.AI.ReAct`                           | `Jido.Slices.AiReact`                       | [task 0047](…) | namespace only                                                                 |
| `Jido.Middleware.Retry`                   | `Jido.Middlewares.Retry`                    | [task 0048](…) | namespace only                                                                 |
| `Jido.Middleware.Persister`               | `Jido.Middlewares.Persister`                | [task 0048](…) | namespace only                                                                 |
| `Jido.Plugin.FSM` (interim)               | `Jido.Plugins.FSM`                          | [task 0049](…) | namespace only                                                                 |
| `Jido.Plugins.FSM` (interim)              | `Jido.Slices.FSM`                           | [b5a1c49](#)   | reclassified Plugin → Slice; no `@behaviour Jido.Middleware` was needed        |
| `Jido.Agent.Directive.{Emit,…}`           | `Jido.Directives.{Emit,…}`                  | [task 0050](…) | umbrella moved to `lib/jido/directives.ex`                                     |
| `Jido.Pod.BusPlugin`                      | `Jido.Slices.ChildBus`                      | [task 0064](…) | reclassified Plugin → Slice + renamed to drop pod-specific framing             |
| `Jido.Pod.BusPlugin.AutoSubscribeChild`   | `Jido.Slices.ChildBus.AutoSubscribeChild`   | [task 0064](…) | follows parent rename                                                          |
| `Jido.Pod.BusPlugin.AutoUnsubscribeChild` | `Jido.Slices.ChildBus.AutoUnsubscribeChild` | [task 0064](…) | follows parent rename                                                          |
| `Jido.Pod`                                | `Jido.Slices.Pod`                           | [task 0065](…) | full subtree move; slice atom `:pod` and host section `pod do … end` unchanged |
| `Jido.Pod.{Runtime,Topology,…}`           | `Jido.Slices.Pod.{Runtime,…}`               | [task 0065](…) | follows parent rename                                                          |
| `Jido.Plugin` (the abstraction)           | depends on task 0066                        | [task 0066](…) | keep, deprecate, or remove                                                     |
```

Pad with the actually-shipped renames; the above is illustrative.

### Bulk-rewrite recipe

Add a fenced shell block under the table:

```sh
# Mechanical namespace rewrites — safe to run on any project.
# Run from the project root.

# Slices: Memory / Identity / Thread / AiReact / FSM
rg -l --type elixir 'Jido\.\(Memory\|Identity\|Thread\)\.Slice' \
  | xargs sed -i 's|Jido\.Memory\.Slice|Jido.Slices.Memory|g'
# … one line per rename …

# Pod (after task 0065):
rg -l --type elixir '\bJido\.Pod\b' \
  | xargs sed -i 's|\bJido\.Pod\b|Jido.Slices.Pod|g'

# Verify:
rg -nP '\b(Jido\.Memory\.Slice|Jido\.Identity\.Slice|Jido\.Thread\.Slice|Jido\.AI\.ReAct|Jido\.Middleware\.(Retry|Persister)|Jido\.Plugins\.FSM|Jido\.Pod(\.|$)|Jido\.Pod\.BusPlugin)\b' .
# expected output: empty
```

### Reclassification cases

The Plugin → Slice reclassifications (FSM, BusPlugin, possibly the deprecation
case from task 0066) require human judgement. Add a callout under the table:

> **If your code currently does `use Jido.Plugin`:** check whether you implement
> any `Jido.Middleware` callback (`call/4`, `init/1`, `on_signal/4`). If not,
> you can switch to `use Jido.Slice` directly — that's what we did for the
> in-tree extensions. If yes, after task 0066 lands you can either keep
> `use Jido.Plugin` (if KEEP) or rewrite to `use Jido.Slice` +
> `@behaviour Jido.Middleware` (if DEPRECATE).

### Cross-reference cleanup

While in the migration guide, audit existing inline updates and consolidate:

- The "## Update — task 0053: `slices do … end` block" callout near the top of
  the guide is post-ADR-0025; the rename map should reference it but not
  duplicate.
- The "## One plugin module migration" section may need a status note pointing
  at task 0066's outcome.

## Acceptance criteria

- [ ] New `## ADR 0025 directory layout — rename map` section in
      `guides/migration-spark-dsl.md`, placed before "## One agent module
      migration".
- [ ] Table covers every rename from tasks 0044, 0045, 0046, 0047, 0048, 0049,
      0050, 0064, 0065, plus the b5a1c49 FSM reclass, plus task 0066's outcome
      for `Jido.Plugin`.
- [ ] Bulk-rewrite shell recipe runs cleanly on a sample external project
      (sanity-check: spin up a throwaway dir, paste an old `Jido.Memory.Slice`
      reference, run the recipe, confirm rewrite).
- [ ] Reclassification callout explains the Plugin → Slice judgement call.
- [ ] Existing "## One plugin module migration" section either updated or
      cross-references the new section as a TL;DR.
- [ ] No code changes; CI green by virtue of being docs only.
- [ ] One commit, prefixed `docs(task-0067):`.

## Out of scope

- Updating the cheat-sheet output (`mix spark.cheat_sheets`) — separate concern;
  cheat sheets regenerate on each release and pick up the new module names
  automatically. If the cheat-sheet rendering carries inline cross-references
  that broke during the rename chain, that's a `mix docs` fix and lives in
  [task 0052](0052-docs-and-cheat-sheets-refresh.md), not here.
- Updating individual ADR documents — they're frozen-in-time decision records;
  cross-references rot is allowed there per the project's docs conventions (see
  `guides/tasks/0020-fix-lib-moduledoc-cross-refs.md` for the established
  policy).
