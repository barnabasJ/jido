# Implementation tasks — ADRs 0014–0016

This directory holds the per-commit task breakdown for implementing [ADR 0014](../adr/0014-slice-middleware-plugin.md), [ADR 0015](../adr/0015-agent-start-is-signal-driven.md), and [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md) as one PR. Plus a foundation commit (C0) that inlines `jido_action` and unifies the action callback signature.

Each task corresponds to exactly one commit. The PR is expected to be **red from commit 2 through commit 7**; commits 0, 1, and 8 are green. The intermediate red is deliberate — keeping each commit green would require temporary shims that churn across the refactor.

| # | Task | Leaves tree | Implements |
|---|---|---|---|
| [0000](0000-inline-action-ctx-threading.md) | Inline `jido_action`; unify action signature; ctx threading | **green** | Foundation (all three ADRs) |
| [0001](0001-slice-middleware-scaffolding.md) | Slice / Middleware scaffolding | **green** | 0014 (scaffolding) |
| [0002](0002-flatten-agent-state-path-required.md) | Flatten `agent.state`; `path:` required; runtime identity on server struct | red | 0014 (agent state shape) |
| [0003](0003-retire-strategy-port-fsm.md) | Retire `Jido.Agent.Strategy`; inline Direct; port FSM to Plugin | red | 0014 (strategy retirement, absorbed from 0011) |
| [0004](0004-middleware-pipeline.md) | Single-tier middleware pipeline; retire legacy plugin hooks; ship Retry middleware | red | 0014 (middleware tier) |
| [0005](0005-migrate-intree-plugins.md) | Rewrite `Jido.Plugin` macro; migrate in-tree plugins; flip `default_plugins` to path-keyed | red | 0014 (Plugin surface + in-repo plugins) |
| [0006](0006-lifecycle-signals-collapse-thaw.md) | Lifecycle signals + `await_ready/2` + collapse thaw paths | red | 0015 |
| [0007](0007-ack-subscribe-primitives.md) | `cast_and_await/4` + `subscribe/4`; retire `await_completion` | red | 0016 |
| [0008](0008-tests-guides-adr-status.md) | Tests, guides, ReAct reference, ADR status flip | **green** | all three — housekeeping |

## Dependencies

```
0000 ← 0001, 0002, 0003, 0004, 0005, 0006, 0007, 0008  (foundation)
0001 ← 0002, 0003, 0004, 0005
0002 ← 0003, 0004, 0005, 0006
0003 ← 0004, 0005
0004 ← 0005, 0006, 0007
0005 ← 0006
0006 ← 0007
0007 ← 0008
```

## Related planning artifacts

- `~/.claude/plans/atomic-whistling-graham.md` — planning-phase notes
- [../review-findings-adrs-0014-0016.md](../review-findings-adrs-0014-0016.md) — review findings; tracks in-progress/resolved decisions across the plan

## Key contracts established by C0 (read before everything else)

- **Action callback**: `run(signal, slice, opts, ctx) :: {:ok, new_slice} | {:ok, new_slice, [directive]} | {:error, reason}`. Four args, always.
- **Middleware callback**: `on_signal(signal, ctx, opts, next) :: {new_ctx, [directive]}`. Four args. `opts` is per-registration, captured via closure when the chain is built.
- **Ctx** is runtime per-signal (user, trace, tenant, plus agent-level runtime identity seeded by AgentServer). Lives on `signal.extensions[:jido_ctx]` on the wire; promoted to explicit arg at action / middleware / directive-exec boundaries. Inherits through emitted signals by default.
- **No deep-merge on action returns**: slice actions return the full new slice. Partial-map merging is gone.
- **`Jido.Agent.ScopedAction` is deleted**; folded into `Jido.Action` with required `path:`.
- **`Jido.Actions.Status.*` is deleted**; convention moves to the migration guide.

## How to use these task docs

Each task doc is scoped tightly enough for a future session to pick one up and execute it without additional planning. The structure is fixed across all tasks:

- **Goal** — what changes, in one paragraph
- **Files to modify** — with file:line refs and inline pseudocode where helpful
- **Files to create / delete** — exhaustive list
- **Acceptance** — how to tell the task is done, including which tests will still be red going into the next task
- **Out of scope** — explicitly excluded work that belongs elsewhere in the PR
- **Risks** — known sharp edges, race conditions, semantic gotchas

Commit messages should reference the task doc filename, e.g.:

```
refactor(adr-0014): flatten agent.state; path required; runtime identity on server struct

Implements guides/tasks/0002-flatten-agent-state-path-required.md
```

This lets reviewers cross-reference code against the scoped plan rather than inferring intent from the diff alone.
