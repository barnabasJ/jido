---
name: Task 0038 — Docs, cheat sheets, migration guide; flip ADR 0023 status to Implemented
description: Run `mix spark.cheat_sheets` to generate per-DSL reference pages under `documentation/dsls/`, wire those into `mix.exs`'s ExDoc config, refresh `guides/agents.md` / `guides/slices.md` / `guides/middleware.md` / `guides/plugins.md` / `guides/your-first-plugin.md` to use sectioned-DSL examples, write a `guides/migration-spark-dsl.md` that walks one in-tree agent and one in-tree slice through the keyword-form → DSL conversion, run `mix spark.formatter` to commit per-DSL `.formatter.exs` entries, and flip `Status: Proposed → Accepted; Implementation: Pending → Complete` in [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md). Final cleanup commit; tree green.
---

# Task 0038 — Docs, cheat sheets, ADR status flip

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) Follow-ups.
- Depends on: [task 0034](0034-port-jido-agent-to-spark.md), [task 0035](0035-port-slice-plugin-middleware-to-spark.md), [task 0036](0036-port-action-and-sensor-to-spark.md), [task 0037](0037-extensions-contribute-dsl-sections.md).
- Blocks: nothing.
- Leaves tree: **green**.

## Context

Tasks 0033–0037 ship the Spark DSL migration end-to-end. Code is
clean; tests pass. What's left is the user-facing surface:

1. **Generated DSL reference.** Spark ships `mix spark.cheat_sheets`
   which produces a Markdown page per DSL extension under
   `documentation/dsls/`. We ship those alongside ExDoc.
2. **Hand-written guide refresh.** The guides currently document the
   keyword-list form (`use Jido.Agent, name: "…", path: …, plugins:
   […]`). Every example rewrites to the sectioned DSL.
3. **Migration guide.** A new guide (`guides/migration-spark-dsl.md`)
   walks a real in-tree agent and a real in-tree slice through the
   keyword → DSL conversion so out-of-tree consumers have a
   concrete walkthrough.
4. **Formatter entries.** `mix spark.formatter --extensions
   Jido.Dsl.Agent,Jido.Dsl.Slice,…` regenerates `.formatter.exs`
   with the per-DSL aliases.
5. **ADR status.** `Status: Proposed → Accepted` and `Implementation:
   Pending → Complete` on ADR 0023.

## Files to modify

### `mix.exs`

1. Add `documentation/dsls/*.md` to ExDoc's `extras:` list with
   appropriate group labels:

   ```elixir
   extras: [
     {"guides/agents.md", title: "Agents"},
     # ...
     {"documentation/dsls/jido-agent.cheatmd", title: "Jido.Agent DSL reference"},
     {"documentation/dsls/jido-slice.cheatmd", title: "Jido.Slice DSL reference"},
     {"documentation/dsls/jido-plugin.cheatmd", title: "Jido.Plugin DSL reference"},
     {"documentation/dsls/jido-middleware.cheatmd", title: "Jido.Middleware DSL reference"},
     {"documentation/dsls/jido-action.cheatmd", title: "Jido.Action DSL reference"},
     {"documentation/dsls/jido-sensor.cheatmd", title: "Jido.Sensor DSL reference"},
     {"documentation/dsls/jido-instance.cheatmd", title: "Jido instance DSL reference"},
     {"guides/migration-spark-dsl.md", title: "Migration: keyword-form → Spark DSL"},
     # ...
   ]
   ```

2. Add a `groups_for_extras:` entry placing the cheat-sheets under a
   "DSL Reference" group.

3. Add a `mix do` alias if helpful:

   ```elixir
   "spark.docs": ["spark.cheat_sheets", "spark.formatter"]
   ```

### `.formatter.exs`

Run:

```sh
mix spark.formatter --extensions Jido.Dsl.Agent,Jido.Dsl.Slice,Jido.Dsl.Plugin,Jido.Dsl.Middleware,Jido.Dsl.Action,Jido.Dsl.Sensor,Jido.Dsl.Instance
```

Commit the resulting `.formatter.exs` diff. The task's `:locals_without_parens`
list will pick up every section / entity name.

### `guides/agents.md`

Refresh every code example. Before:

```elixir
use Jido.Agent,
  name: "my_agent",
  path: :domain,
  schema: [...]
```

After:

```elixir
use Jido.Agent

agent do
  name "my_agent"
  path :domain
  schema [...]
end
```

Same treatment for `signal_routes:`, `plugins:`, `slices:`,
`middleware:`, `schedules:` examples scattered through the guide.

### `guides/slices.md`, `guides/slices.livemd`

Refresh every `use Jido.Slice, …` example to the sectioned form.

### `guides/middleware.md`, `guides/middleware.livemd`

Refresh every `use Jido.Middleware, …` example. Add a paragraph
about the `middleware do schema […] end` section for middleware
authors who want typed `opts`.

### `guides/plugins.md`, `guides/plugins.livemd`

Refresh every `use Jido.Plugin, …` example. Add a paragraph about
`use Jido.Slice.Extension, host_section: :react` and the
contributed-section path.

### `guides/your-first-plugin.md`

End-to-end walkthrough: rewrite from scratch around the sectioned
DSL plus a `Slice.Extension` opt-in. Show one host agent picking up
the contributed section.

### `guides/getting-started.livemd`

Refresh the "define an agent" cell to use the sectioned DSL.

### `guides/migration.md`

Add a "Spark DSL migration (ADR 0023)" section linking to the new
`migration-spark-dsl.md` guide.

### `README.md`

Refresh the top-level Quick Start example to use the sectioned DSL.

### `usage-rules.md`

Refresh any `use Jido.X` reference to the sectioned form.

### `guides/adr/0023-spark-dsl-and-registerable-extensions.md`

Flip front matter:

```diff
- - Status: Proposed
+ - Status: Accepted
- - Implementation: Pending
+ - Implementation: Complete
```

Add the implementing commit SHAs to the `Related ADRs` line if
useful.

### `guides/adr/README.md`

Add a row for ADR 0023 in the index, status `Accepted` /
`Implementation: Complete`.

### `guides/tasks/README.md`

Add rows for tasks 0033–0038 with status, plus add the `0033 ←
0034 ← 0035 ← 0036 ← 0037 ← 0038` chain to the dependency graph.

## Files to create

### `documentation/dsls/jido-agent.cheatmd`, …, `jido-instance.cheatmd`

Generated by `mix spark.cheat_sheets`. Commit verbatim. (The file
extension is `.cheatmd` — Spark's cheat-sheet format that ExDoc
renders.)

### `guides/migration-spark-dsl.md`

A new guide that walks through:

1. **Why we're migrating** (1 paragraph linking to ADR 0023).
2. **One agent module migration** — pick a representative in-tree
   agent (a test agent works), show the before / after, point at the
   concrete diff in the PR.
3. **One slice module migration** — same, for a slice.
4. **One plugin module migration** — same, for a plugin.
5. **The `extensions: […]` opt-in** — explain when to declare a
   slice via `slices do slice Mod, … end` vs `extensions: [Mod]` plus
   `mod_section do … end`.
6. **Common pitfalls** — keyword `do:` blocks vs `do … end` blocks,
   `nimble_options`-shaped section schemas vs Zoi-shaped runtime
   schemas, formatter quirks.

Length target: 400–600 lines including code blocks.

## Files to delete

- Any obsolete `guides/spark-cheat-sheet.md` placeholder (none today).
- Any guide example that referenced retired `state_key:` or
  `default_plugins:` shapes that this round of refreshes also
  removes.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean.
- `mix docs` runs clean — no broken cross-references; the new cheat
  sheets render under their group; the migration guide renders.
- `mix spark.cheat_sheets` re-run produces no diff (idempotent).
- Spot-check: `MyApp.SupportAgent` example from
  `migration-spark-dsl.md` compiles when copy-pasted into a fresh
  project test file.
- ADR 0023 front matter is updated in the same commit.

## Out of scope

- New conceptual content for any guide. This is a *refresh* — we
  rewrite examples to the new shape but don't restructure or
  re-explain. Conceptual rewrites are their own task if needed.
- Igniter generators (`mix jido.gen.agent`, `mix jido.gen.slice`).
  ADR 0023's Follow-ups list these as out of scope; revisit in a
  later task.
- A blog-post-style "what's new in jido X.Y" announcement. The
  `CHANGELOG.md` entry covers it.

## Risks

- **`mix spark.cheat_sheets` output stability.** Spark's
  cheat-sheet generator output has occasionally drifted between
  minor versions; pin the Spark version before generating. If a
  later Spark bump regenerates with formatting changes, that's a
  one-line follow-up to commit the new output.
- **Guide example count.** The refresh touches every guide that
  references `use Jido.X, …`. The diff is large but mechanical;
  review by guide.
- **`README.md` quickstart in sync with `lib/jido.ex` moduledoc.**
  Both contain a Quick Start example. Keep them in sync.
