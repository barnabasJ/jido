---
name: Task 0016 — Livebook docs for post-refactor features
description: Author runnable .livemd guides for each major feature surface ADRs 0014–0021 reshaped, so contributors can interactively verify behavior end-to-end.
---

# Task 0016 — Livebook docs for post-refactor features

- Implements: documentation companion for [ADR 0014](../adr/0014-slice-middleware-plugin.md) through [ADR 0021](../adr/0021-no-full-state-no-polling.md). No production code changes.
- Depends on: [task 0015](0015-strict-directives-no-runtime-state.md) (terminal code task — every feature exercised below assumes the strict directive contract).
- Blocks: nothing.
- Leaves tree: **green** (docs-only).

## Goal

Ship one runnable Livebook (`.livemd`) per major feature surface the 0014–0021 refactor reshaped. Each notebook is **demo-only** — no test harness, no CI evaluation. A reader opens the file in Livebook, evaluates top-to-bottom, and sees the post-refactor API behave the way the ADRs describe.

The bar is "evaluable end-to-end against a fresh `mix.install/1` of this repo's current `main`." Drift surfaces when someone opens the file; we accept that cost in exchange for not building a livebook test runner this PR.

The existing `guides/getting-started.livemd` stays as the entry point. The eight new files are deeper dives, each scoped to one coherent feature area.

## Notebook layout (shared shape)

Every new `.livemd` follows the same skeleton so readers can context-switch between them without re-learning the conventions:

1. **Mix.install** — pin to the local repo (`path: "../.."` from the livemd's location, or `git:` against `main` if reading on GitHub).
2. **Setup section** — define a `Demo.Jido` instance module via `use Jido, otp_app: :demo`, start it with `Demo.Jido.start_link/0`. Identical across all notebooks.
3. **Concept section** — short prose tying the feature back to its ADR. One paragraph; link the ADR by relative path so it works on GitHub.
4. **Worked example** — define the minimal agent / slice / plugin / middleware, evaluate signals against it, `IO.inspect/2` the resulting state or signals at each step.
5. **Variations** — 1–3 follow-up cells exploring edges (failure paths, race windows, alternate signatures). Keep each variation self-contained — readers should be able to run any one in isolation.
6. **Cleanup** — `Demo.Jido.stop_agent/1` for any agent started; the LiveNode itself stays so subsequent cells can be re-run.

No assertions. No `assert/1`-style checks. The "verification" is the reader's eyes on the `IO.inspect` output. If a cell raises, it raises — that's the failure signal.

## Files to create

All under `guides/`. File order below is also the recommended authoring order — earlier notebooks introduce concepts later ones reuse.

### `guides/slices.livemd`

Implements the demo for [ADR 0014](../adr/0014-slice-middleware-plugin.md) §slice + [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) §3 (multi-slice via return shape).

Cover:

- `use Jido.Slice` with `path:`, `schema:`, `signal_routes:`, `subscriptions:`.
- Defining a slice action (`use Jido.Action, path: :counter`) with the four-arg `run/4` signature.
- Reading slice state via `agent.state[:counter]`.
- Multi-slice writes via `%Jido.Agent.SliceUpdate{}` returns — show one action that updates two slices in one step.
- Composition: an agent module with two slices, sending one signal that hits both via routes.

Reference: `guides/slices.md`. The livebook is the runnable companion — don't duplicate the prose, link to it.

### `guides/middleware.livemd`

Implements the demo for [ADR 0014](../adr/0014-slice-middleware-plugin.md) §middleware.

Cover:

- `on_signal(signal, ctx, opts, next)` — show the four args, the `next.()` call, what comes back.
- Chain composition order: build a 3-stage chain (log-before, retry, log-after) and demonstrate ordering by inspecting the log.
- `Jido.Middleware.Retry` with retry-on-error and retry-until-condition.
- `ctx.agent` mutation as the documented exception (Persister-style staging) — show one minimal middleware that sets a slice key on `lifecycle.starting`.
- Brief contrast with the retired `handle_signal/2` / `transform_result/3` plugin callbacks. Don't dwell — `migration.md` covers it.

Reference: `guides/middleware.md`.

### `guides/plugins.livemd`

Implements the demo for [ADR 0014](../adr/0014-slice-middleware-plugin.md) §plugin (the combo model).

Cover:

- A plugin module that composes a Slice + Middleware + a small bit of config-derived state.
- The `mount/2`-retired four patterns (per [task 0008](0008-tests-guides-adr-status.md) migration.md additions): nothing, echo config, compile-time derive, runtime-derive via `lifecycle.starting` action. Show the simplest two as runnable cells; reference the migration guide for the rest.
- `default_plugins:` on an agent vs per-instance `{Plugin, config}`.

Reference: `guides/plugins.md`.

### `guides/actions-and-directives.livemd`

Implements the demo for [ADR 0018](../adr/0018-tagged-tuple-return-shape.md) (return shape) + [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) (rule + directive surface).

Cover:

- Action's `run/4` returning `{:ok, slice}` / `{:ok, slice, [directive]}` / `{:error, reason}`.
- A directive that's pure I/O (`Jido.Agent.Directive.Emit`) — show its return is `:ok | {:stop, reason}`, nothing else.
- The cascade pattern from [task 0015](0015-strict-directives-no-runtime-state.md): action emits a `RunInstruction` directive → directive emits a result signal → routed action consumes the signal and updates the slice. Walk through with three IEx-style cells: send the signal, observe each step, inspect final slice.
- Demonstrate the SpawnAgent → `child.started` → `maybe_track_child_started/2` cascade: send a SpawnAgent directive, immediately `state.children` is empty, `Process.sleep(50)`, now it's populated. Use this to illustrate the async-window risk noted in task 0015.

Reference: `guides/state-ops.md` (post-StateOp), `guides/directives.md`.

### `guides/call-cast-await-subscribe.livemd`

Implements the demo for [ADR 0015](../adr/0015-agent-start-is-signal-driven.md) (lifecycle), [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md) (ack/subscribe), [ADR 0020](../adr/0020-synchronous-call-takes-a-selector.md) (selector-based call).

Cover:

- `AgentServer.call/4` with a selector — show that the return is whatever the selector projects, not the full agent state. Demonstrate one selector that picks a single field, one that returns a derived value.
- `AgentServer.cast/2` for fire-and-forget.
- `AgentServer.cast_and_await/4` — show retry-until-condition, swallow-on-non-match, caller-DOWN behavior.
- `AgentServer.subscribe/4` — fan-out to multiple subscribers; `once: true`; pattern matching on signal type.
- `AgentServer.await_ready/2` — pre-thaw vs post-thaw timing; show that `start_agent/2` returns before `ready` fires when the agent has a Persister middleware doing thaw I/O.

Reference: `guides/runtime-patterns.md`.

### `guides/pods.livemd`

Implements the demo for [ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md) + [ADR 0021](../adr/0021-no-full-state-no-polling.md) (Pod-side projection).

Cover:

- Defining a Pod (`use Jido.Pod`) and starting one.
- `Pod.mutate/3` — issue a mutation, observe `pod.mutation.status` transition `:idle → :running → :completed`.
- `Pod.mutate_and_wait/3` — same but blocking on the natural `child.*` cascade.
- The `Pod.Runtime.View` projection: `Pod.nodes/1`, `Pod.lookup_node/2` — show that consumers get a targeted projection, not the raw `state.children` map.
- One failure case: a child that fails to boot, `pod.mutation.status: :failed`, the failed entry's reason field.

Reference: `guides/pods.md`.

### `guides/cron-children-lifecycle.livemd`

Implements the demo for the resource-tracking cascade pattern shipped in [task 0015](0015-strict-directives-no-runtime-state.md), spanning [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) §2 and [ADR 0015](../adr/0015-agent-start-is-signal-driven.md) §lifecycle signals.

Cover:

- `Jido.Agent.Directive.Cron` — register a cron job, observe `jido.agent.cron.registered` arrive, `state.cron_specs[id]` populate via `maybe_track_cron_registered/2`. Cancel via `CronCancel`, observe the matching `cron.cancelled` cascade.
- `Jido.Agent.Directive.SpawnAgent` — same shape, `child.started` → `state.children[tag]`.
- `Jido.Agent.Directive.AdoptChild` — adopt an already-running agent; observe `child.started` cascade still fires.
- `parent_died` / `orphaned` lifecycle signals — start a child under a parent, kill the parent, watch the child's mailbox.

Reference: `guides/scheduling.md`, `guides/orphans.md`.

### `guides/observability.livemd`

Implements the demo for the observability surface — telemetry, traces, debug events — that survives across the refactor.

Cover:

- `:telemetry` events emitted by directive execution; attach a handler in-cell and inspect events as signals fire.
- `Jido.AgentServer.TraceContext` — show ctx threading across emitted signals (`signal.extensions[:jido_ctx]`).
- `state.debug_events` ring buffer — read recent events via a `state/3` selector after a sequence of signals.
- Targeted reads via selectors per [ADR 0021](../adr/0021-no-full-state-no-polling.md) — contrast against the retired "fetch full state and dig" pattern.

Reference: `guides/observability.md`, `guides/debugging.md`.

## Files to modify

### `guides/getting-started.livemd`

Append a "Where to go next" section linking each new livebook by relative path so a reader landing in Livebook can navigate the set without leaving the runtime.

### `guides/tasks/README.md`

Add a row for task 0016 to the index table:

```
| [0016](0016-livebook-docs-for-features.md) | Livebook docs for post-refactor features (8 .livemd files) | **green** | Documentation companion to ADRs 0014–0021 |
```

Update the dependency block to note `0015 ← 0016`.

## Files to delete

None.

## Acceptance

- Eight new `.livemd` files under `guides/`, named per the list above.
- Each file opens cleanly in Livebook (`livebook server`) and evaluates top-to-bottom against the current `main` of this repo without raising.
- Each file follows the shared skeleton (Mix.install → Demo.Jido → Concept → Worked example → Variations → Cleanup).
- `guides/getting-started.livemd` links to all eight at the bottom.
- `guides/tasks/README.md` index includes 0016.
- No production code changes — `git diff main -- lib/ test/` is empty.
- No assertions inside livebook cells. `IO.inspect/2` is the verification tool.

## Out of scope

- **Headless livebook test runner.** No `kino_test`, no CI eval pass. If a livebook drifts, it surfaces when someone opens it. A future task can wire CI evaluation; this task ships the content.
- **Rewriting the prose `.md` guides.** Several guides under `guides/` still describe pre-refactor surfaces (per task 0008's "deferred to follow-up PR" list). That overhaul is its own task. Each new livebook links to the corresponding `.md` for prose; if the `.md` is stale, the livebook is the trustworthy companion until the rewrite lands.
- **Integration livemds** — `ash-integration.livemd`, `phoenix-integration.livemd`, `multi-tenancy.livemd`. Defer to follow-up; each pulls in third-party deps that complicate the Mix.install story and aren't part of the 0014–0021 refactor proper.
- **The ReAct reference example.** Per task 0008's S4, that's a separate post-refactor follow-up.

## Risks

- **Mix.install pinning.** Livebooks evaluate against a snapshot of the repo at install time. If we pin to `path:`, the livebook only runs from the repo checkout (fine for local verification, breaks the GitHub "Run in Livebook" badge). If we pin to `git: ... ref: "main"`, the badge works but the livebook can't be evaluated against an in-flight branch. Recommend: **path-pin** during this task (the user asked for verification, which is local), then a follow-up flips to `git:` once the refactor is on `main` and a release is cut.
- **Async windows in cascade demos.** The `actions-and-directives.livemd` and `cron-children-lifecycle.livemd` notebooks rely on `Process.sleep/1` to span the directive → cascade window. That's fine for a demo (it's the same pattern any user writing a script would use) but it's intrinsically race-prone — on a slow machine, 50ms might not be enough. Use `await_state_value/3` from `JidoTest.AgentWait` (or a re-export of it under `Jido.Test` if we want it public) instead of raw sleeps where possible. If the helpers aren't on the public surface, document the sleep with a "this is a demo; use `subscribe/4` in production" note.
- **Drift.** No CI catches drift. Mitigation: each livebook references the ADR(s) it demos by section number; when an ADR changes, grep `guides/*.livemd` for the ADR number to find dependent livebooks. Add this grep to the PR template's review checklist as a one-line item.
- **Notebook size.** Eight files is on the high end. If during authoring two notebooks heavily overlap (e.g., `slices.livemd` and `actions-and-directives.livemd` both end up demonstrating slice updates), merge them and leave a redirect cell at the top of the absorbed file. Don't ship near-duplicate content.
