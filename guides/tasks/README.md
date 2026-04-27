# Implementation tasks — ADRs 0014–0020

This directory holds the per-commit task breakdown for implementing [ADR 0014](../adr/0014-slice-middleware-plugin.md), [ADR 0015](../adr/0015-agent-start-is-signal-driven.md), [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md), [ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md), [ADR 0018](../adr/0018-tagged-tuple-return-shape.md), [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md), [ADR 0020](../adr/0020-synchronous-call-takes-a-selector.md), and [ADR 0021](../adr/0021-no-full-state-no-polling.md).

The 0014–0016 work shipped as one PR (commits C0–C8). The 0017–0020 follow-on work lands in five sequential commits, each its own session: **task 0011 first** (the tagged-tuple return shape; ADR 0018), then **task 0009** (the Pod.mutate API refactor on top of 0011; ADR 0017 Phase 1), then **task 0012** (delete StateOp directives + multi-slice via return shape; ADR 0019), then **task 0013** (`call/4` takes a selector; `cast_and_await/4` retires; ADR 0020), then **task 0010** (Pod runtime signal-driven state machine; ADR 0017 Phase 2 under ADR 0019's strict separation rule, using `call/4` from 0013). 0011 ships first because it simplifies every selector and Retry-style middleware downstream. 0012 / 0013 are independent cleanup tasks that both land before 0010 — 0012 to clean up state-mutation channels, 0013 to unify the synchronous primitive — so 0010's diff stays focused on the runtime state machine without dragging in primitive renames.

After 0010, **task 0015** lands as the terminal ADR 0019 cleanup: tightens the agent-side directive surface (`SpawnAgent`, `AdoptChild`, `Cron`, `CronCancel`, `RunInstruction`) to the same strict rule the Pod state machine already follows. The Pod surface was the worked example; 0015 generalises it so the principle "directives mutate no state" holds uniformly.

> # NO LEGACY ADAPTERS — APPLIES TO EVERY TASK BELOW
>
> When a task says "rewrite X to Y", **rewrite it**. Do not write a shim,
> a `__before_compile__` adapter, a translation layer, a "transitional"
> code path that accepts both shapes, or any other piece of code whose
> only purpose is to keep the old API working alongside the new one.
>
> There are **no external users to protect** here. This codebase ships
> the framework — anyone consuming it is in this repo, in their own
> repo, or has agreed to follow the migration. We do not owe any of
> them a smooth runtime upgrade. We owe them a clean, opinionated API
> they can read in five minutes.
>
> Every adapter is bug-bait that outlives the migration: it doubles the
> surface area, hides the new shape behind a translation, and makes the
> next refactor harder. If a task fixture or call site doesn't match the
> new shape, **rewrite the fixture or call site** — including in tests.
> Tests are not load-bearing for backwards compatibility; they are
> verification of current behaviour.
>
> Concretely, this rules out:
>
> - `run/2` shims wrapped into `run/4` via macros
> - `state_key/0` fallbacks alongside `path/0`
> - "if `context[:state]` is set, treat it as the slice" branches in `Exec`
> - "if `params` is a map and `signal` is nil, synthesize a signal" code
>   that is reachable from in-repo callers
> - any `@deprecated` callback declarations that we still call ourselves
>
> If a synthesis exists, it exists for **one** reason: to support
> calling `Jido.Exec.run/4` directly from a test or REPL with raw
> `(action, params, context, opts)`. That is a developer-affordance
> entry point. The agent_server / cmd / signal_router path always
> hands a real `%Jido.Signal{}` to the action and never relies on
> synthesis.

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
| [0011](0011-tagged-tuple-return-shape.md) | Tagged-tuple return shape across action / cmd / middleware; ack reads chain outcome | **green** | 0018 |
| [0009](0009-pod-mutate-cast-await-api.md) | `Pod.mutate` switches to `cast_and_await` + lifecycle signals; add `Pod.mutate_and_wait/3` | **green** | 0017 (Phase 1 — public API) |
| [0012](0012-delete-state-op-directives.md) | Delete `Jido.Agent.StateOp.*`; re-path actions; multi-slice via `%SliceUpdate{}` return shape | **green** | 0019 |
| [0013](0013-call-takes-selector-cast-and-await-retires.md) | `AgentServer.call/4` takes a selector; delete `cast_and_await/4` + state-returning `call/3`; extract `process_signal/2` helper | **green** | 0020 |
| [0014](0014-no-full-state-no-polling-pod-runtime-and-tests.md) | `Pod.Runtime` projects a `View` struct; delete `eventually_state/3`; replace polling with subscriptions; rewrite full-state test reads as targeted selectors | **green** | 0021 |
| [0010](0010-pod-runtime-signal-driven-state-machine.md) | Pod runtime: signal-driven state machine; delete wave orchestration; drop synthetic `jido.pod.mutate.{completed,failed}` lifecycle signal; rewrite `Pod.mutate_and_wait/3` around natural child lifecycle signals; enforce ADR 0019 on Pod surface | **green** | 0017 (Phase 2 — runtime simplification) + 0019 (Pod surface enforcement) |
| [0015](0015-strict-directives-no-runtime-state.md) | Tighten `DirectiveExec.exec/3` contract to `:ok \| {:stop, term()}` (no state in return — type-system enforces "directives mutate no state"); split `SpawnAgent` / `AdoptChild` / `Cron` / `CronCancel` / `RunInstruction`; add `maybe_track_cron_registered/2` + `maybe_track_cron_cancelled/2` cascade callbacks; route `RunInstruction`'s result via signal_routes | **green** | 0019 (cross-cutting tightening + type-system enforcement) |
| [0016](0016-livebook-docs-for-features.md) | Livebook docs for post-refactor features (8 .livemd files) | **green** | Documentation companion to ADRs 0014–0021 |
| [0017](0017-slice-owned-routes-and-terminology.md) | Move slice-owned routes onto slices; clarify `plugins:` accepts slices | **green** | Documentation correction to ADR 0014 + task 0016 livebooks |

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
0008 ← 0011              (ADR 0018 — first of the follow-on chain)
0011 ← 0009              (ADR 0017 Phase 1 — uses 0011's simplified selectors)
0009 ← 0012              (ADR 0019 — StateOp deletion, re-path Pod.Actions.Mutate)
0012 ← 0013              (ADR 0020 — call/4 takes a selector; cast_and_await retires)
0013 ← 0014              (ADR 0021 — Pod.Runtime View struct; tests subscribe instead of poll)
0014 ← 0010              (ADR 0017 Phase 2 — uses call/4 + View, assumes StateOp gone)
0010 ← 0015              (ADR 0019 — terminal cleanup; agent-side directives split to match Pod surface)
0015 ← 0016              (docs companion — runnable livebooks for every major feature surface)
0016 ← 0017              (docs follow-up — fix slice-owned routes antipattern + ADR 0014 terminology drift)
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
