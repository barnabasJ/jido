---
name: Task 0052 — Refresh docs and cheat sheets; flip ADR 0025 to Accepted/Complete
description: Terminal commit of the ADR-0025 chain. Run `mix spark.cheat_sheets` for the final regen with all module names settled. Refresh `guides/agents.md`, `guides/slices.md`, `guides/middleware.md`, `guides/plugins.md`, `guides/directives.md`, and `guides/migration-spark-dsl.md` to use the new module names. Add a "Layout" section to `guides/architecture.md` (or a new `guides/layout.md` if architecture.md doesn't exist) describing the `lib/jido/{slices,middlewares,plugins,directives}/` convention so out-of-tree extension authors mirror it. Flip ADR 0025 status to Accepted / Implementation Complete. Update `guides/tasks/README.md` index and dependency graph for 0043–0052.
---

# Task 0052 — Refresh docs, cheat sheets, layout guide; flip ADR 0025 status

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) Follow-ups (terminal commit).
- Depends on: [task 0043](0043-delete-misnamed-agent-helpers.md), [task 0044](0044-move-rename-memory-slice.md), [task 0045](0045-move-rename-identity-slice.md), [task 0046](0046-move-rename-thread-slice.md), [task 0047](0047-move-rename-ai-react-slice.md), [task 0048](0048-move-rename-middlewares.md), [task 0049](0049-move-rename-fsm-plugin.md), [task 0050](0050-lift-framework-directives.md), [task 0051](0051-heartbeat-telemetry-config-cleanup.md).
- Blocks: nothing.
- Leaves tree: **green**.

## Context

Tasks 0043–0051 land the layout reorg end-to-end. Code is clean;
tests pass. Three things are left:

1. **Generated DSL reference.** `mix spark.cheat_sheets` was
   regenerated incrementally during tasks 0044–0049, but with all
   module names settled the final regen produces the canonical
   output.
2. **Hand-written guide refresh.** Every code example referencing
   `Jido.Memory.Slice`, `Jido.Plugin.FSM`, `Jido.Agent.Directive.Emit`,
   etc. needs the new name.
3. **Layout guide.** ADR 0025 establishes a convention that out-of-tree
   extension authors should mirror. The convention deserves a guide,
   not just an ADR — readers should land on `guides/` and find a
   short orientation page describing the directory shape.

## Goal

After this commit:

- `mix spark.cheat_sheets` is idempotent (rerun produces no diff).
- Every guide / livebook / module-doc example uses the new names.
- A "Layout" section / guide exists.
- ADR 0025 front matter reads `Status: Accepted, Implementation: Complete`.
- `guides/tasks/README.md` lists 0043–0052 with their statuses.

## Files to modify

### `documentation/dsls/*.cheatmd`

```sh
mix spark.cheat_sheets
```

Commit the resulting diff — this is the canonical post-rename output.
Cross-references to module names update to the renamed forms.

### `guides/agents.md`

Refresh every example that references the old names:

- `Jido.Memory.Slice` → `Jido.Slices.Memory`
- `Jido.Identity.Slice` → `Jido.Slices.Identity`
- `Jido.Thread.Slice` → `Jido.Slices.Thread`
- `Jido.AI.ReAct` → `Jido.Slices.AiReact`
- `Jido.Middleware.Retry` → `Jido.Middlewares.Retry`
- `Jido.Middleware.Persister` → `Jido.Middlewares.Persister`
- `Jido.Plugin.FSM` → `Jido.Plugins.FSM`
- `Jido.Agent.Directive.Emit` → `Jido.Directives.Emit` (and
  every other directive)
- `Jido.Memory` (data type) → `Jido.Slices.Memory.State`
- `Jido.Identity` (data type) → `Jido.Slices.Identity.State`
- `Jido.Thread` (data type) → `Jido.Slices.Thread.State`

The bulk-rewrites in tasks 0044–0050 already touched these guide
files mechanically; this task does a careful read-through to confirm
prose still makes sense (a `Jido.Memory.State` mention reads
differently from `Jido.Memory` — sometimes a sentence needs a
rewrite, not just a substitution).

### `guides/slices.md`

Same treatment. Add a paragraph documenting the `lib/jido/slices/`
convention — point at the new layout guide.

### `guides/middleware.md`, `guides/middleware.livemd`

Same.

### `guides/plugins.md`, `guides/plugins.livemd`, `guides/your-first-plugin.md`

Same. The "your-first-plugin" walkthrough is end-to-end; verify
the code-block compiles when copy-pasted.

### `guides/directives.md`

Substantial rewrite of the directive table — the namespace changed
from `Jido.Agent.Directive.*` to `Jido.Directives.*`, and the
inline-vs-file split disappears (every directive is now its own
file).

Add a paragraph distinguishing **framework directives**
(`Jido.Directives.*`) from **slice-owned directives** (e.g.
`Jido.Slices.AiReact.Directives.LLMCall`, `Jido.Pod.Directive.StartNode`).
Frame the rule from ADR 0025 §2: framework directives lift to the
top-level `directives/`; slice-owned directives ride along with
their slice in a `directives/` subdirectory.

### `guides/migration-spark-dsl.md`

Existing migration guide for the ADR-0023 keyword → DSL conversion.
Add a new section "Module renames in ADR 0025" with a one-table
listing of every old → new module name, plus a paragraph on the
file-layout convention.

### `guides/getting-started.livemd`

The Quickstart cell uses one or more of the renamed modules.
Refresh and re-evaluate.

### `livebooks/*.livemd`

Every livebook touched by the bulk-rewrite gets a final read-through:
`memory.livemd`, `thread.livemd`, `identity.livemd` (if present),
`llm-agent.livemd`, `middleware.livemd`, `plugins.livemd`. Re-evaluate
each cell end-to-end.

### `README.md`

Top-level Quickstart in the README references the renamed modules.
Update.

### `usage-rules.md`

Top-level "how to use Jido" reference. Update any module-name
references.

### `lib/jido.ex`, `lib/jido/agent.ex`, `lib/jido/slice.ex` moduledocs

Every framework module's moduledoc that contains an example using
the old names. The bulk-rewrite handled the literal references;
this task does a sanity read-through.

### `guides/adr/0025-extension-directory-layout.md`

Flip front matter:

```diff
- - Status: Proposed
+ - Status: Accepted
- - Implementation: Pending
+ - Implementation: Complete
```

Add the implementing-commit SHAs to the `Related commits:` line if
they are known at the time of the commit.

### `guides/adr/README.md`

Add a row for ADR 0025 in the index, status `Accepted` /
`Implementation: Complete`.

### `guides/tasks/README.md`

Add rows for tasks 0043–0052 in the table, plus a dependency-graph
update. Suggested entry:

```
0043 ← 0044 ← 0045 ← 0046 ← 0047 ← 0048 ← 0049 ← 0050 ← 0051 ← 0052
                                                                   (ADR 0025 — extension directory layout)
```

(Or whichever shape best matches the existing graph style. 0043 is
independent of the renames; 0044–0049 are the slice/middleware/plugin
renames; 0050 is the directives lift; 0051 is the small companion
cleanups; 0052 is the docs terminal.)

## Files to create

### `guides/layout.md` (or extend `guides/architecture.md`)

A short orientation page (200–400 lines) describing:

1. **The four extension surfaces.** Slice, middleware, plugin,
   directive — each gets its own top-level `lib/jido/<plural>/`
   directory. Each built-in extension is one file
   (`lib/jido/slices/memory.ex`) plus a same-named subdirectory
   for supporting types and actions
   (`lib/jido/slices/memory/{state,space,actions/}`).
2. **Framework infrastructure stays put.** `lib/jido/agent/`,
   `lib/jido/agent_server/`, `lib/jido/slice/`, `lib/jido/plugin/`
   (without `fsm.ex`), `lib/jido/middleware.ex` (the framework
   base), `lib/jido/dsl/`, `lib/jido/exec/`, `lib/jido/persist.ex`,
   etc. — these are the framework, not extensions, and they live
   at their natural locations.
3. **Pod is its own thing.** `lib/jido/pod/` — pod is a special
   agent kind with tightly-coupled plugins and directives. It does
   not split across `lib/jido/plugins/` and `lib/jido/directives/`.
4. **Out-of-tree authors mirror the convention.** A library author
   shipping `MyOrg.Slices.MySlice` would put it at
   `lib/my_org/slices/my_slice.ex` with supporting types under
   `lib/my_org/slices/my_slice/`. Same pattern for middlewares,
   plugins, directives.
5. **Directives: framework vs slice-owned.** Framework directives
   live at top-level `lib/jido/directives/` because any action can
   emit them. Slice-owned directives live inside the slice
   (`lib/jido/slices/<slice>/directives/`) because only that slice's
   actions emit them.
6. **The naming convention.** Module name follows the directory:
   `Jido.Slices.<Name>`, `Jido.Middlewares.<Name>`, `Jido.Plugins.<Name>`,
   `Jido.Directives.<Name>`. The data-type struct of a slice is
   `Jido.Slices.<Name>.State`. Actions are `Jido.Slices.<Name>.Actions.*`.

Add a link to this guide from the README, from `guides/architecture.md`
(if it exists), and from ADR 0025's Consequences section.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean.
- `mix test --include e2e` clean.
- `mix docs` runs clean — no broken cross-references; the layout
  guide renders.
- `mix spark.cheat_sheets` re-run produces no diff (idempotent).
- Spot-check: every Quickstart example in `README.md`,
  `lib/jido.ex`, `guides/getting-started.livemd`, and
  `guides/agents.md` compiles when copy-pasted into a fresh project.
- `git grep -nE 'Jido\.(Memory|Identity|Thread|AI\.ReAct|Memory\.Slice|Identity\.Slice|Thread\.Slice|Plugin\.FSM|Middleware\.Retry|Middleware\.Persister|Agent\.Directive)\b'`
  in `lib/`, `test/`, `guides/`, `livebooks/` returns zero hits
  except in `guides/tasks/` and `guides/adr/` (historical records).
- ADR 0025 front matter shows `Status: Accepted, Implementation:
  Complete`.

## Out of scope

- Conceptual rewrites of any guide. This is a *refresh* — examples
  rewrite to the new names, but no restructuring. If a guide needs
  a structural rewrite, that's its own task.
- New ADRs beyond ADR 0025 (e.g. extracting `Jido.AI` into a
  separate package). Mentioned in ADR 0025 §5 as a future ADR; not
  this task.
- Igniter generators (`mix jido.gen.slice`, `mix jido.gen.middleware`,
  `mix jido.gen.plugin`). Useful, but a separate task.

## Risks

- **A sentence in a guide reads oddly after the bulk rewrite.**
  Example: "The `Jido.Memory` struct holds spaces" reads worse as
  "The `Jido.Slices.Memory.State` struct holds spaces" — the latter
  needs a rephrase to "Memory state, stored at `agent.state[:memory]`,
  is a `Jido.Slices.Memory.State` struct holding spaces." Plan for
  a careful read-through, not just a search-and-replace.
- **`mix docs` flags a moduledoc cross-reference that the bulk
  rewrite missed.** Likely a backtick-quoted module name inside a
  paragraph. Easy fix; surfaces during `mix docs`.
- **The layout guide drifts from the actual layout over time.** The
  guide is point-in-time; if a future ADR moves the lines again,
  the guide updates with it. Not a now-risk, but worth noting.
