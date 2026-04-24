# Task 0008 — Tests, guides, ADR status (restores green)

- Commit #: 8 of 9 — **the commit that turns the tree green again**
- Implements: housekeeping for [ADR 0014](../adr/0014-slice-middleware-plugin.md), [ADR 0015](../adr/0015-agent-start-is-signal-driven.md), [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md)
- Depends on: 0000, 0001, 0002, 0003, 0004, 0005, 0006, 0007
- Blocks: —
- Leaves tree: **green**

## Goal

Make the full test suite pass, ship the new/rewritten guides (minimized per S3), and flip the three implementing ADRs to `Status: Implemented`. This is the only commit where `mix test` must pass top-to-bottom. The ReAct reference example is deferred to a follow-up PR (per S4).

The work is in four loosely independent sub-tracks, all in one commit: tests, guides, example, ADR updates.

## Test migration

### Rewrite (update shape, mostly mechanical)

Path renames (`:__domain__` → declared path; `state_key:` → `path:`) are mechanical:

- [test/jido/agent/agent_test.exs](../../test/jido/agent/agent_test.exs)
- [test/jido/agent/schema_test.exs](../../test/jido/agent/schema_test.exs), `schema_coverage_test.exs`
- [test/jido/agent/signal_handling_test.exs](../../test/jido/agent/signal_handling_test.exs)
- [test/jido/agent/state_test.exs](../../test/jido/agent/state_test.exs), `state_op_test.exs`, `state_ops_test.exs`
- [test/jido/agent/directive_test.exs](../../test/jido/agent/directive_test.exs)
- [test/jido/agent/default_plugins_test.exs](../../test/jido/agent/default_plugins_test.exs)
- [test/jido/agent_server/agent_server_test.exs](../../test/jido/agent_server/agent_server_test.exs), `agent_server_coverage_test.exs`, `agent_server_stop_log_test.exs`
- [test/jido/agent_server/cron_integration_test.exs](../../test/jido/agent_server/cron_integration_test.exs), `cron_tick_delivery_test.exs`
- [test/jido/agent_server/directive_exec_test.exs](../../test/jido/agent_server/directive_exec_test.exs), `multi_directive_atomicity_test.exs`, `signal_directive_ordering_test.exs`
- [test/jido/agent_server/hierarchy_test.exs](../../test/jido/agent_server/hierarchy_test.exs), `parent_ref_test.exs`, `plugin_children_test.exs`
- [test/jido/agent_server/signal_router_test.exs](../../test/jido/agent_server/signal_router_test.exs), `signal_test.exs`
- [test/jido/agent_server/telemetry_test.exs](../../test/jido/agent_server/telemetry_test.exs), `trace_propagation_test.exs`
- [test/jido/plugin/instance_test.exs](../../test/jido/plugin/instance_test.exs), `manifest_test.exs`, `plugin_test.exs`, `routes_test.exs`, `requirements_test.exs`, `schedules_test.exs`, `singleton_compile_test.exs`
- [test/jido/agent_plugin_integration_test.exs](../../test/jido/agent_plugin_integration_test.exs), `agent_pool_test.exs`
- [test/jido/thread_test.exs](../../test/jido/thread_test.exs)
- [test/jido/pod/*.exs](../../test/jido/pod/) — all path references
- [test/jido/persist_test.exs](../../test/jido/persist_test.exs) — update to new hibernate/thaw shape; no legacy-key coverage (round-3 W10 dropped the migration pass)
- [test/examples/basics/*.exs](../../test/examples/basics/)
- [test/examples/plugins/*.exs](../../test/examples/plugins/) — esp. `identity_plugin_test.exs`, `thread_plugin_test.exs`, `memory_plugin_test.exs`, `plugin_basics_test.exs`, `default_plugin_override_test.exs`
- [test/examples/signals/*.exs](../../test/examples/signals/), `runtime/*.exs`, `observability/*.exs`, `persistence/*.exs`

### Rewrite (substantive — semantics changed)

These tests change more than path names; they exercise retired surfaces and need genuine rewrites:

- **FSM tests** — [test/jido/agent/strategy_fsm_test.exs](../../test/jido/agent/strategy_fsm_test.exs) (448 lines): rewrite against `Jido.Plugin.FSM`. Preserve semantic coverage.
- **FSM example** — [test/examples/fsm/fsm_agent_test.exs](../../test/examples/fsm/fsm_agent_test.exs), `fsm_strategy_guide_test.exs`: rewrite to exercise `Jido.Plugin.FSM` at `path: :fsm`.
- **Await tests** — [test/jido/await_test.exs](../../test/jido/await_test.exs) (354 lines), `await_coverage_test.exs`: **deleted** per W6 resolution — `Jido.Await` module is gone entirely. New tests for `cast_and_await/4` / `subscribe/4` live under `test/jido/agent_server/ack_subscribe_test.exs`.
- **Hibernate/thaw** — [test/jido/integration/hibernate_thaw_test.exs](../../test/jido/integration/hibernate_thaw_test.exs) (409 lines): rewrite against the single-path thaw in `AgentServer.init/1`. Add assertions that `restored_from_storage` no longer exists as a runtime concept.
- **Persist checkpoint/restore** — [test/examples/persistence/checkpoint_restore_test.exs](../../test/examples/persistence/checkpoint_restore_test.exs): rewrite against `Jido.Middleware.Persister`.
- **Instance manager** — [test/jido/agent/instance_manager_test.exs](../../test/jido/agent/instance_manager_test.exs): drop all `restored_from_storage` assertions; assert that `get/3` + `await_ready/2` is the correct start-and-wait pattern.
- **Scheduler** — [test/jido/agent/schedules_test.exs](../../test/jido/agent/schedules_test.exs), `schedules_integration_test.exs`: confirm cron-spec persistence still works via Persist; update any plugin path refs.
- **Plugin subscriptions** — [test/jido/agent_server/plugin_subscriptions_test.exs](../../test/jido/agent_server/plugin_subscriptions_test.exs): keep tests for static `subscriptions:` (survives as a Slice field); drop tests for dynamic `subscriptions/2` callback (retired with the old plugin surface).

### Delete (retiring entirely)

- [test/jido/agent_server/plugin_signal_hooks_test.exs](../../test/jido/agent_server/plugin_signal_hooks_test.exs) — covers retired `handle_signal/2`. Middleware coverage replaces.
- [test/jido/agent_server/plugin_signal_middleware_test.exs](../../test/jido/agent_server/plugin_signal_middleware_test.exs) (609 lines) — covers the legacy hook "middleware" flavor. Replaced by new middleware tests (below).
- [test/jido/agent_server/plugin_transform_test.exs](../../test/jido/agent_server/plugin_transform_test.exs) — covers retired `transform_result/3`.
- [test/jido/agent_server/error_policy_test.exs](../../test/jido/agent_server/error_policy_test.exs) — covers retired `error_policy:` option.
- [test/jido/agent_server/strategy_init_test.exs](../../test/jido/agent_server/strategy_init_test.exs) — strategy.init retires with Strategy itself.
- [test/jido/agent/strategy_test.exs](../../test/jido/agent/strategy_test.exs), `strategy_state_test.exs` — Strategy abstraction is gone.
- [test/jido/plugin/checkpoint_hooks_test.exs](../../test/jido/plugin/checkpoint_hooks_test.exs), `restore_hooks_test.exs`, `plugin_mount_test.exs`, `plugin_lifecycle_test.exs` — retired plugin callbacks.
- [test/examples/plugins/plugin_middleware_test.exs](../../test/examples/plugins/plugin_middleware_test.exs) (318 lines) — the "plugin middleware" example built on `handle_signal`. Replaced by the new middleware guide examples in this commit.
- [test/jido/actions/status_test.exs](../../test/jido/actions/status_test.exs) — `Jido.Actions.Status.*` deleted in C0. No replacement; convention moves to migration guide.
- [test/jido/agent_server/status_test.exs](../../test/jido/agent_server/status_test.exs), [test/jido/agent_server/status_struct_test.exs](../../test/jido/agent_server/status_struct_test.exs) — `Jido.AgentServer.Status` module deleted in C3 per W8. No replacement.

### New tests

- `test/jido/slice_test.exs` — compile-time validation, accessor round-trips, schema defaults
- `test/jido/middleware_test.exs` — behaviour contract, `use` macro
- `test/jido/middleware/persister_test.exs` — hibernate + thaw round-trip via the Persister middleware (blocking IO in on_signal/4; ctx.agent mutation; completion signals emitted), with and without transforms
- `test/jido/middleware/retry_test.exs` — retry-on-error, retry-until-success, max-attempts-exceeded, pattern filtering
- `test/jido/agent_server/middleware_pipeline_test.exs` — chain composition order, retry correctness, error propagation, ctx shape
- `test/jido/agent_server/lifecycle_signals_test.exs` — `starting/ready/stopping` emission order, `await_ready/2` happy-path + already-ready + timeout + DOWN
- `test/jido/agent_server/ack_subscribe_test.exs` — `cast_and_await/4` (retry, swallow, selector raise, caller DOWN); `subscribe/4` (fan-out, unsubscribe, DOWN, pattern match)
- `test/jido/plugin/fsm_test.exs` — covers Jido.Plugin.FSM as a Slice + Middleware (replaces `strategy_fsm_test` deletions)
- `test/jido/agent_server/identity_signals_test.exs` — `partition_assigned`, `parent_died`, `orphaned` emission

## Reference example: ReAct-as-Plugin — **deferred to follow-up PR**

The existing `test/examples/react/react_plugin_test.exs` is a skipped design-sketch moduledoc (pseudocode only, `@moduletag :skip`). It references retired ADRs 0011/0012 but no code depends on it. Per S4, rewriting it to an executable example is deferred — it depends on middleware (Retry, LoopTimeout) and directive extensions (SpawnTask) that are out of scope for this PR.

Leave the file alone in this PR. The post-refactor PR will decide whether to rewrite, update, or delete it.

## Guide rewrites

**Scope minimized per S3 resolution**: most existing guides are left stale until a follow-up post-refactor PR overhauls them. Only what's strictly necessary ships in this commit.

### New guides (required — new concepts)

- `guides/slices.md` — declarative reducer tier. Cover: `use Jido.Slice`, all config fields with examples, composition with other slices, accessing slice state via `agent.state[path]`, slice-declared routes, schema defaults and validation. Reference ADR 0014 for design rationale.
- `guides/middleware.md` — single-tier `next`-passing wrap. Cover: `on_signal/4` contract (signal, ctx, opts, next), `next` semantics, chain composition order, use cases (gate, transform, retry, persist, error convert, log), stateless vs. Plugin-paired state, interaction with `cast_and_await`/`subscribe` (retry transparency, swallow).

### Rewrites (required — existing guide teaches retired surface)

- `guides/plugins.md` — rewrite around the combo model. Cover: when a module should be Slice vs Plugin vs Middleware-only, the contract for each, how to migrate from the pre-0014 plugin surface (recipe list: `state_key:` → `path:`, `handle_signal/2` → `on_signal/4` before-next, `transform_result/3` → `on_signal/4` after-next, `on_checkpoint/2` → Persister middleware MFA, `mount/2` → four-pattern migration per S2).
- `guides/migration.md` — add these migration sections:
  - **Plugin surface**: pre-0014 plugin callbacks → Slice/Middleware/Plugin. Include the table from C5.
  - **`mount/2` retired — four replacement patterns** (per S2 resolution):
    1. **Nothing (`{:ok, nil}`)**: just delete the callback; schema defaults cover.
    2. **Echo config into slice**: `Agent.new/1` automatically merges `{Plugin, config}` into `agent.state[plugin.path]` on top of schema defaults. Zero code needed.
    3. **Compile-time derivation from agent module**: use a wrapper macro like `use Jido.Pod` that overrides `new/1` to inject `initial_state:`. Show the Pod example.
    4. **Runtime-derived (rare)**: declare a Slice action routed on `jido.agent.lifecycle.starting` that computes and writes state via a `StateOp.SetPath` directive.
  - **Action callback shape**: `run(params, context)` → `run(signal, slice, opts, ctx)`. Migration recipes with before/after code samples.
  - **No more deep-merge**: actions return the full slice; partial-map return semantics are gone. Show idiomatic conversions (e.g., `{:ok, %{counter: n+1}}` → `{:ok, %{slice | counter: n+1}}`).
  - **`Jido.Agent.ScopedAction` folded in**: users of `use Jido.Agent.ScopedAction, state_key: :x` migrate to `use Jido.Action, path: :x`.
  - **`Jido.Actions.Status.*` removed**: users who had `{"work.done", Jido.Actions.Status.MarkCompleted}` inline the convention with a small action in their own code. Show a ~10-line replacement snippet.
  - **`error_policy:` agent option removed, no direct replacement in this PR**: error-handling model is deferred to a follow-up PR. Users who relied on `error_policy: :log_only` or `:stop_on_error` either (a) write a ~10-line middleware in user code (scan `%Error{}` directives after `next`; log or append `%Stop{}`), or (b) wait for the follow-up. Show both snippets as reference.
  - **`Jido.Await` removed**: users who called `Jido.Await.completion/3` rewrite to `AgentServer.subscribe/4` with a selector matching their own terminal status convention. Show a ~15-line reference implementation with `once: true`.
  - **`Jido.AgentServer.Status` removed**: users who called `AgentServer.status/1` switch to `AgentServer.state/1` and inspect whatever shape they need.
  - **Ctx threading**: new primitives for passing `current_user`, `trace_id`, etc. through signals via `signal.extensions[:jido_ctx]`. `cast_and_await/4` and `subscribe/4` accept `ctx:` opt.
  - **Pre-refactor checkpoints are not forward-compatible**: per ADR 0014's "no external users exist" assumption, no migration pass ships. Local dev or test-fixture checkpoints from before this PR should be regenerated by running the post-refactor code from fresh.
  - **`Directive.emit_to_parent/3` removed**: users rewrite to `%Directive.Emit{dispatch: {:pid, target: ctx.parent.pid}}` using the `ctx.parent` key seeded at signal receipt. Show a ~5-line snippet including the orphaned-case guard (`if ctx.parent, do: ..., else: []`).
  - **Retry middleware vs Persister IO failures**: `Jido.Middleware.Retry` DOES cover Persister IO failures, *provided* Retry is positioned outside Persister in the middleware chain. Persister's middleware half blocks on thaw/hibernate IO synchronously; if it raises, Retry (if wrapping) catches and re-invokes `next`. Chain ordering is user-declared at the agent module level — put Retry first if you want retry-on-thaw. The error-handling model is otherwise user-owned in this PR; the follow-up PR formalizes it.
  - **Hibernate-on-terminate vs supervisor shutdown timeout**: `lifecycle.stopping` emits at the top of `terminate/2`; Persister middleware blocks on hibernate IO synchronously. If the IO exceeds the supervisor's `shutdown:` timeout (default 5_000 ms), the process is killed mid-write and the checkpoint is partial. The bound is the supervisor's timeout, not anything the framework enforces. Users with slow storage adapters must bump `shutdown:` accordingly when configuring the agent's child_spec.
  - **`InstanceManager.get/3` semantics change**: previously thawed synchronously before returning; now returns the pid as soon as the process is alive, and thaw runs inside AgentServer's `init/1` via the Persister plugin's `lifecycle.starting` observer. Callers that assumed "get returned pid ⇒ thawed state available" must insert `await_ready/2` between get and first signal send. InstanceManager does not wrap `await_ready` automatically — liveness vs readiness is the caller's concern.

### Delete

- `guides/strategies.md`
- `guides/custom-strategies.md`
- `guides/fsm-strategy.livemd`
- `guides/await.md` (module is gone; migration section in `migration.md` covers the replacement pattern)

### Deferred to follow-up PR

The following guides describe pre-refactor internals and will be stale after this PR lands. A follow-up PR will overhaul them (per user direction):

- `guides/agents.md`, `core-loop.md`, `configuration.md`
- `guides/your-first-plugin.md`, `phoenix-integration.md`
- `guides/orphans.md`, `observability.md`, `observability-intro.md`
- `guides/runtime.md`, `runtime-patterns.md`
- `guides/storage.md`, `scheduling.md`

## ADR updates

### Flip to Implemented

- [guides/adr/0014-slice-middleware-plugin.md](../adr/0014-slice-middleware-plugin.md) — `Status: Proposed` → `Status: Implemented`. `Implementation: Pending` → `Implementation: Complete`. Fill `Related commits:` with the nine hashes from this PR (C0–C8).
- [guides/adr/0015-agent-start-is-signal-driven.md](../adr/0015-agent-start-is-signal-driven.md) — same.
- [guides/adr/0016-agent-server-ack-and-subscribe.md](../adr/0016-agent-server-ack-and-subscribe.md) — same.

### Add `Superseded by` pointers

- [guides/adr/0007-agent-lifecycle-is-signal-driven.md](../adr/0007-agent-lifecycle-is-signal-driven.md) — already marked `Superseded by: [0015]` per ADR 0015 header; verify the header is in place.
- [guides/adr/0010-waiting-via-ack-and-subscribe.md](../adr/0010-waiting-via-ack-and-subscribe.md) — add `Superseded by: [0016]`.
- [guides/adr/0013-slices-middleware-plugins.md](../adr/0013-slices-middleware-plugins.md) — already marked superseded by 0014; verify.
- [guides/adr/0011-retire-strategy-plugins-are-control-flow.md](../adr/0011-retire-strategy-plugins-are-control-flow.md), [guides/adr/0012-middleware-for-cross-cutting-concerns.md](../adr/0012-middleware-for-cross-cutting-concerns.md) — already point to 0013; verify the chain.

### Leave alone

- [guides/adr/0007-implementation.md](../adr/0007-implementation.md) — kept for historical record; no changes.

## Mix task & generator updates

- [lib/mix/tasks/jido.gen.plugin.ex](../../lib/mix/tasks/jido.gen.plugin.ex), [lib/jido/igniter/templates.ex](../../lib/jido/igniter/templates.ex) (already touched in C5 for the `path:` rename): ensure the help text and any README snippets generated by `mix jido.gen.plugin` describe the Slice/Middleware/Plugin model accurately. Also update `mix jido.gen.agent` if it mentions `state_key:` or `strategy:`.

## Acceptance

- `mix compile --warnings-as-errors` passes
- `mix test` **green top-to-bottom** — no skipped tests, no failures
- `mix credo --strict` clean (no new warnings)
- `mix docs` builds without errors; new guides are indexed
- Every deleted test file has a plausible replacement in the new test list
- Grepping `guides/` for `state_key`, `strategy:`, `__domain__`, `__thread__`, `error_policy` returns zero hits (outside of migration guide examples)

## Out of scope

- Follow-up work listed in ADR 0014: the remaining standard middleware (`Logger`, `Retry`, `CircuitBreaker`) — those are separate PRs.
- API reference docs regeneration if pulled from `@doc` strings — should flow automatically from the `mix docs` build.

## Risks

- **Scope**: this commit is inherently large. Structure the work in a consistent order within the commit: (1) run the test suite, catalogue failures, (2) for each failure, classify as rewrite/delete/new-test, (3) work through the list, (4) rewrite guides, (5) flip ADRs. Don't interleave.
- **Silent regressions in deleted tests**: some tests cover edge cases not covered anywhere else. For each deletion in the "Delete" list, scan its `test`/`describe` blocks and confirm every assertion has a replacement in a new/rewritten test. Example: `checkpoint_hooks_test.exs` scenarios must be in `persister_test.exs`. `error_policy_test.exs` has no automatic replacement — its error-handling semantics are intentionally not re-shipped; migration guide covers the self-roll path.
- **Guide-code divergence**: running snippets from the guides against the current build catches drift. Ensure new guide examples are verifiable by copy-pasting into IEx against a clean build.
