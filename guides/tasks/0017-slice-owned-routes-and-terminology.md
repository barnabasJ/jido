---
name: Task 0017 — Slice-owned routes and `plugins:` terminology
description: Fix the antipattern where slice-owned signal routes live on the agent's signal_routes/1 callback instead of the slice's signal_routes: option, and clarify the `plugins:` accepts slices reality vs ADR 0014's proposed `slices:` key.
---

# Task 0017 — Slice-owned routes and `plugins:` terminology

- Implements: docs follow-up to [task 0016](0016-livebook-docs-for-features.md). No production code changes; covers the eight new livebooks plus the prose guides that demonstrate slice composition.
- Depends on: [task 0016](0016-livebook-docs-for-features.md) (ships the livebooks this task corrects).
- Blocks: nothing.
- Leaves tree: **green** (docs-only).

## Goal

Two things, both surfaced while reviewing the task 0016 livebooks:

### 1. Slice-owned routes belong on the slice

A slice owns a `path:` and the actions that mutate it. In current code (and per [ADR 0014](../adr/0014-slice-middleware-plugin.md) §slice), `signal_routes:` is part of the slice's compile-time surface and gets aggregated into the agent's route table at compile time via `Jido.Plugin.Routes.expand_routes/1`. The agent's own `signal_routes/1` callback is for routes that genuinely don't belong to a single slice — cross-slice flows, one-off agent-only routes.

Seven of the eight new livebooks (everything except `slices.livemd`) declare slice-owned actions via the agent's `def signal_routes(_ctx) do [...]` callback, splitting the slice's identity across two modules. The action declares `path: :counter`, the slice declares `path: :counter`, but the route lives on the agent. Reading the slice doesn't tell you what signals it handles.

Fix: route declarations whose action's `path:` matches a slice's `path:` move onto that slice's `signal_routes:` option. Cross-slice routes stay on the agent.

### 2. `plugins:` accepts slices — the ADR's `slices:` key never shipped

[ADR 0014](../adr/0014-slice-middleware-plugin.md) §slice proposes three separate agent options — `slices:`, `middleware:`, `plugins:`. The implementation merged `slices` and `plugins` into a single `plugins:` option that accepts anything implementing the plugin protocol (a bare `use Jido.Slice` module exports `plugin_spec/1`, so it qualifies). There is **no** `slices:` option on `use Jido.Agent`.

The terminology drift confuses readers — they see `plugins: [CounterSlice]` and reasonably ask "why is a slice called a plugin?" The answer: in current code, "plugin" is the umbrella term for "thing with a slice surface attached to an agent."

Fix two parts:

1. Update [ADR 0014](../adr/0014-slice-middleware-plugin.md) to match the code — drop the proposed `slices:` key from the example, document that `plugins:` is the singular option that accepts both bare slices and slice + middleware combos. The decision trail in §Alternatives Considered should note that the three-key shape was simplified to two keys at implementation time.
2. Add a brief terminology call-out near the top of `guides/slices.livemd` (and the prose `guides/slices.md`) explaining `plugins:` accepts both slices and plugin combos.

The alternative — adding a `slices:` option to the agent that's an alias for `plugins:` — would expand surface area without semantic gain. The agent doesn't care whether the attached module has a middleware half; it only cares about the plugin protocol. One key, not two.

## Files to modify

### Livebooks under `guides/` (audit + fix all eight)

For each file, walk the action/slice/agent declarations and move any route whose action's `path:` matches a declared slice's `path:` onto that slice's `signal_routes:` option. Also move the action module itself into the slice's `actions: [...]` list.

Routes that don't fit a single slice (cross-slice flows, demo-only routes that hit a top-level action) stay on the agent — flag them with a comment explaining why (e.g., "this route bridges slices, so it lives on the agent").

| File | Current pattern | Fix |
|---|---|---|
| [`guides/slices.livemd`](../slices.livemd) | Mixed — most routes on agent, one slice with `signal_routes:` | Move counter routes onto `CounterSlice` |
| [`guides/middleware.livemd`](../middleware.livemd) | All routes on agent | Move `flaky` route onto a `FlakySlice` if appropriate; keep the per-action middleware composition demos as-is |
| [`guides/plugins.livemd`](../plugins.livemd) | Routes on agent for `MetricsAgent` and `RoutedCounterAgent` | Move `metrics.tick` onto `MetricsPlugin`; the routed counter demo's routes belong on `CounterPlugin` |
| [`guides/actions-and-directives.livemd`](../actions-and-directives.livemd) | Routes on agent throughout | Move routes onto `ObservedSlice` (or split into multiple slices if the demo benefits) |
| [`guides/call-cast-await-subscribe.livemd`](../call-cast-await-subscribe.livemd) | Routes on agent | Move `counter.inc` onto a `CounterSlice`; keep `fail` on the agent (or split into a separate slice) |
| [`guides/pods.livemd`](../pods.livemd) | Pods don't expose user-defined routes here; review whether the worker agent declarations could benefit | Probably no change needed — pod runtime owns its routing |
| [`guides/cron-children-lifecycle.livemd`](../cron-children-lifecycle.livemd) | Routes on agent | The `emit` route stays on the agent (it's a generic harness, not slice-owned). Audit and document the rationale. |
| [`guides/observability.livemd`](../observability.livemd) | Routes on agent | Move `counter.inc` and `emit.event` onto their owning slices |

### Add a terminology note to `guides/slices.livemd`

In the **Concept** section, add one sentence near the top:

> Slices attach to agents via the `plugins:` option — there is no separate `slices:` key. ADR 0014 proposed splitting them; the implementation merged into a single `plugins:` that accepts both bare slices and slice + middleware combos. See [the agent declaration shape](#) for examples.

### Update `guides/adr/0014-slice-middleware-plugin.md`

- In the example block under §Path-based registration, replace `slices: [...]` with `plugins: [...]` and remove the standalone `plugins: [...]` line (or keep both lines if the demo wants to show two distinct registrations) — match what compile-time validation actually accepts.
- Add a short note under §Alternatives considered (or a new §Implementation deviation section) recording that the three-key proposal (`slices:`, `middleware:`, `plugins:`) collapsed to two keys (`plugins:`, `middleware:`) during implementation, and why: the `slices:` key would have been a duplicate of `plugins:` once `plugin_spec/1` became the protocol both share.

### Update `guides/slices.md` (prose)

Same terminology note as the livebook. If the prose already uses `slices:`, fix it. (Audit pending — task 0008's "deferred prose rewrite" still applies; this task only fixes the specific `slices:` vs `plugins:` callout, not a full guide rewrite.)

### Update `guides/tasks/README.md`

Add a row for task 0017:

```
| [0017](0017-slice-owned-routes-and-terminology.md) | Move slice-owned routes onto slices; clarify `plugins:` accepts slices | **green** | Documentation correction to ADR 0014 + task 0016 livebooks |
```

Update the dependency block: `0016 ← 0017`.

## Files to create

None.

## Files to delete

None.

## Acceptance

- Every livebook under `guides/*.livemd` evaluates top-to-bottom via `mix run scripts/verify_livemd.exs` (no regressions from the fix-up).
- Routes whose action's `path:` matches a declared slice's `path:` live on the slice's `signal_routes:` option, not on the agent's `signal_routes/1` callback.
- Cross-slice / agent-only routes that genuinely don't belong to a single slice stay on the agent, with an inline comment documenting why.
- `guides/slices.livemd` has a terminology note clarifying that `plugins:` accepts slices.
- ADR 0014's example uses `plugins:` (matching the code), and a short `§Implementation deviation` note records the three-key → two-key collapse.
- `guides/tasks/README.md` indexes task 0017.
- `git diff main -- lib/ test/` is empty — no production code changes.

## Out of scope

- **Adding a `slices:` option to `use Jido.Agent`.** The path forward is to update the ADR to match the code, not to expand the agent's option surface. If a future maintainer disagrees and wants to add `slices:` as a stricter alternative (e.g., validates the module has no middleware half), that's a separate ADR and a separate task.
- **Rewriting the prose `guides/*.md` files end-to-end.** Per task 0008's "deferred follow-up" list, the prose overhaul is its own task. This task only fixes the specific `plugins:`/`slices:` terminology mention in `guides/slices.md` and `guides/plugins.md`; broader prose updates wait.
- **Auditing in-tree plugin/slice modules** (e.g., `Jido.Thread.Plugin`, `Jido.Identity.Plugin`) — they're already correct (slice-only, no agent-side routes for them).
- **Test fixture updates** — every test fixture I checked (`test/jido/agent_plugin_integration_test.exs`, etc.) already uses the canonical `plugins: [Slice]` shape with slice-side routes. If the audit turns up a test fixture that does the antipattern, fix it as part of this task; otherwise leave them alone.

## Risks

- **Slice ordering.** Putting `signal_routes: [{"foo", MyAction}]` on a slice requires `MyAction` to be defined *before* the slice. Several livebooks currently put the agent block last with all action references resolved by then; the slice block above the action wouldn't compile. The fix is to define actions first, then slices, then the agent. This is a mechanical reordering — note it explicitly in each fix so the next reader doesn't trip on it.
- **Cross-slice routes are real.** Don't force every route onto a slice. The `RunInstruction` cascade in `actions-and-directives.livemd` has a result signal that bridges slices intentionally — the routed handler updates a slice it doesn't formally "own." Routes like that stay on the agent with a comment.
- **Verifier coverage.** The smoke check (`mix run scripts/verify_livemd.exs`) catches missing modules / syntax errors but does not assert that the cells produce the same `IO.inspect` output as before. Spot-check a few cells visually after the fix.
