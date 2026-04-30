# Implementation tasks — ADRs 0014–0022

This directory holds the per-commit task breakdown for implementing [ADR 0014](../adr/0014-slice-middleware-plugin.md), [ADR 0015](../adr/0015-agent-start-is-signal-driven.md), [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md), [ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md), [ADR 0018](../adr/0018-tagged-tuple-return-shape.md), [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md), [ADR 0020](../adr/0020-synchronous-call-takes-a-selector.md), [ADR 0021](../adr/0021-no-full-state-no-polling.md), and [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md).

Tasks 0021–0024 form the additive chain that implements ADR 0022 (inlined LLM-agent subsystem under `Jido.AI.*` on top of `req_llm`). Each commit leaves the tree green — the namespace is new, no existing code is touched. 0021 (`req_llm` dep + `Jido.AI.ToolAdapter` + `Jido.AI.Turn` ported from `jido_ai`) → 0022 (synchronous ReAct loop calling `ReqLLM.Generation.generate_text/3`, Mimic-stubbed in tests) → 0023 (signal-driven agent envelope: slice + actions + custom directives + `use Jido.AI.Agent` macro) → 0024 (livebook with configurable model spec + local-LLM integration test). 0023 is the keystone: it wraps the synchronous loop in a slice / actions / custom-directive shape that conforms to ADR 0019 (no side effects in actions) and ADR 0021 (waits subscribe, never poll). The two test/demo rules are kept distinct: the **integration test targets a local LLM** with probe-and-skip (no API keys), and the **livebook exposes the model spec as a configurable input** so the reader picks the provider.

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
| [0018](0018-refresh-user-guides-for-adr-0019.md) | Refresh user-facing guides for ADR 0019 strict rule: rewrite stale `Jido.Agent.StateOp` examples in `agents.md` / `actions.md` / `orchestration.md` / `plugins.md` / `middleware.md` / `scheduling.md` / `migration.md` / `your-first-plugin.md` to use slice-return + `%SliceUpdate{}` shape; delete `guides/state-ops.md`; remove the "Heads up" banners | **green** | 0019 (per-guide documentation cleanup) |
| [0019](0019-remove-process-sleep-from-livebooks.md) | Remove `Process.sleep` from livebooks; use `subscribe/4` instead | **green** | Documentation correction to task 0016 livebooks (ADR 0021 enforcement) |
| [0020](0020-fix-lib-moduledoc-cross-refs.md) | Fix lib/ moduledoc cross-references caught by `mix docs`: `../adr/...` → `../../guides/adr/...` typos; unqualified `Agent.new/1` / `Agent.cmd/2` refs; wrong-arity `expand_route/2` → public `expand_routes/1` | **green** | Documentation hygiene follow-up to task 0018 (lib/ moduledoc warnings the docs-only constraint blocked) |
| [0021](0021-reqllm-dep-and-tool-adapter.md) | Add `req_llm` dep + port `Jido.AI.ToolAdapter` + port `Jido.AI.Turn` | **green** | [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §2 §4 |
| [0022](0022-react-runtime-pure.md) | `Jido.AI.ReAct` synchronous loop over `ReqLLM.Generation`, no agent dep — **superseded by 0030** (the slice is the only ReAct in v2) | **green** | ADR 0022 v1 §5 — retired by ADR 0022 v2 |
| [0023](0023-llm-agent-slice-plugin.md) | `Jido.AI.Agent` macro + slice + actions + custom directives (signal-driven envelope) — **superseded by 0030** (no AI-specific agent macro in v2) | **green** | ADR 0022 v1 §6 — retired by ADR 0022 v2 |
| [0024](0024-llm-agent-livebook-and-local-integration-test.md) | Livebook with configurable model input + local-LLM integration test (probe-and-skip) + docs index — **superseded by 0031** (tagged-not-probed, slice composition) | **pending** | ADR 0022 v1 §7 §8 — retired by ADR 0022 v2 |
| [0025](0025-pod-reconcile-lifecycle-signals.md) | Pod reconcile lifecycle signals: restore the three `jido.pod.reconcile.*` casts in `Pod.Runtime.reconcile/2`, or supersede ADR 0004 because the post-ADR-0017 mutation state machine subsumes them | **green** | [ADR 0004](../adr/0004-pod-lifecycle-signals.md) — code/ADR realignment |
| [0026](0026-jido-agent-directive-internal-consistency.md) | `Jido.Agent.Directive` internal consistency: surface `Reply` and `SpawnManagedAgent` in the alias block + `@type core`; complete the `## Core Directives` moduledoc list (`Cron`, `CronCancel`, `Reply`, `SpawnManagedAgent`) | **green** | Documentation hygiene (lib/) |
| [0027](0027-refresh-guides-round-2.md) | Refresh user-facing guides round 2: rewrite stale `Jido.Agent.Strategy` (ADR 0011), `{agent, directives}` `cmd/2` shape (ADR 0018), `Pod.mutate/3` `{:ok, report}` shape (ADR 0017), and `result_action:` (task 0015) examples across `agents.md`, `actions.md`, `directives.md`, `runtime.md`, `signals.md`, `pods.md`, `migration.md`; add missing `Reply` / `SpawnManagedAgent` rows to the directive table | **green** | Documentation cleanup follow-up to task 0018 |
| [0028](0028-fire-post-signal-hooks-adr-alignment.md) | Align ADR 0018 §3 with the implemented `fire_post_signal_hooks/2` (subscribers-only) split — ack dispatch lives at the call site, not in this hook | **green** | ADR 0018 §3 spec hygiene |
| [0029](0029-reject-bare-slice-in-plugins.md) | Reject bare `use Jido.Slice` modules in `plugins:` at compile time — a plugin is `Slice + Middleware`; bare slices belong in `slices:` (added by task 0032). Pairs with 0032 | **pending** | ADR 0014 (plugin = slice + middleware) — closes a framework validation gap |
| [0032](0032-framework-slices-attachment-option.md) | Framework: add `slices: [Module \| {Module, config}]` to `use Jido.Agent`. Mounts each at `module.path()`, seeds initial state from config through `module.config_schema/0`, registers `signal_routes/0` with absolute paths (no plugin prefixing). Rename framework singletons `Jido.{Identity,Memory,Thread}.Plugin` → `*.Slice` (they were always slices). Pairs with 0029 | **pending** | ADR 0014 (proper slice attachment) — supports [ADR 0022 v3](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §6 |
| [0030](0030-llm-agent-slice-composition-refactor.md) | Refactor LLM agent: `Jido.AI.ReAct` is `use Jido.Slice` with `config_schema` (model/tools/system_prompt/etc.); users compose via `use Jido.Agent, slices: [{Jido.AI.ReAct, ...}]`. Delete `Jido.AI.Agent` macro and `Jido.AI.ReAct.run/2`. User-facing API moves to `Jido.AI.{ask,await,ask_sync}/N`. Supersedes the user-facing surface of tasks 0022/0023 | **green** | [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) v3 §6 §7 |
| [0031](0031-llm-agent-livebook-and-tagged-integration-tests.md) | `guides/llm-agent.livemd` with the model spec as a `Kino.Input` (configurable, the reader picks). Headline cell streams ReAct steps live into a `Kino.Frame` via an out-of-band subscription. Agent-level integration tests under `:e2e` already shipped by task 0030 — excluded by default, run via `mix test --include e2e`, no probe-and-skip. Docs-index wiring. Supersedes task 0024 | **green** | [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) v3.1 §8 §9 |
| [0033](0033-spark-dep-and-jido-dsl-scaffold.md) | Add `:spark` dep + scaffold `Jido.Dsl.*` namespace (empty placeholder modules + formatter wiring) | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 — scaffolding |
| [0034](0034-port-jido-agent-to-spark.md) | Port `use Jido.Agent` and `use Jido` to Spark DSL: host-owned `agent` / `signal_routes` / `schedules` sections; per-extension typed blocks contributed by modules listed in `use Jido.Agent, extensions: [...]`; kind inferred from markers; chain order from the keyword list; same compile-time aggregations via Spark transformers / verifiers; runtime API unchanged | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 §2 §3 §6 |
| [0035](0035-port-slice-plugin-middleware-to-spark.md) | Port `use Jido.Slice`, `use Jido.Plugin`, `use Jido.Middleware` to Spark DSL; in-tree slices / plugins / middleware migrate; `__jido_slice__` / `__jido_plugin__` markers preserved | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 §4 mechanics |
| [0036](0036-port-action-and-sensor-to-spark.md) | Port `use Jido.Action` and `use Jido.Sensor` to Spark DSL; in-tree actions / sensors migrate; tree returns to green | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 |
| [0037](0037-slice-dsl-cleanup.md) | Slice DSL cleanup — drop redundant `actions do` (derive from `signal_routes`); drop `singleton:` (gates collapse to path-based checks); pod-plugin replacement contract uses path + capability instead | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 §4 |
| [0038](0038-agent-dsl-optional-path-and-extension-path-override.md) | Agent DSL: `path` optional unless `schema` is set (path-less composition agents valid); per-extension `path:` override on contributed sections (host renames mount path inline) | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §2 §4 |
| [0039](0039-slices-must-declare-schema-and-routes.md) | Every slice declares a state schema and at least one signal route; promote `Jido.{Memory,Identity,Thread}.Slice` to real slices with shape + actions + routes; sibling `*.Agent` helper modules collapse | **green** | [ADR 0014](../adr/0014-slice-middleware-plugin.md) (Slice as composition unit), [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 §4 |
| [0040](0040-use-spark-tooling-everywhere.md) | Replace hand-rolled accessors with `Spark.InfoGenerator` Info modules; replace `__jido_slice__/0` / `__jido_plugin__/0` markers with `Spark.Dsl.is?/2`; replace `__plugin_metadata__/0` etc. discovery callbacks with Spark-walk in `Jido.Discovery`; delete `Jido.Plugin.Manifest` projection struct + `manifest/0` / `plugin_spec/1` host accessors | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 |
| [0041](0041-extensions-contribute-dsl-sections.md) | Each extension contributes its own typed DSL block to host agents — `use Jido.Agent, extensions: [Jido.AI.ReAct]` unlocks `react do … end`. `Jido.Slice.Extension` macro + per-host discovery transformer; `WalkExtensions` reads the typed-block config; `Jido.AI.ReAct`, `Jido.{Identity,Memory,Thread}.Slice` all opt in. `Jido.Pod` migrates to its own Spark DSL host (`Jido.Dsl.Pod`); every in-tree `use Jido.Pod, …` keyword-form site rewrites. Deletes `Jido.Dsl.Agent.LegacyTranslator`, `Jido.Agent`'s `@agent_config_schema` Zoi schema, and the `Jido.Agent.config_schema/0` accessor. Strips transitional `(task 003N)` qualifiers from moduledocs | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §4 |
| [0042](0042-docs-and-cleanup.md) | `mix spark.cheat_sheets` per-DSL reference under `documentation/dsls/`, `mix spark.formatter` aliases, refresh `guides/agents.md` / `slices.md` / `middleware.md` / `plugins.md` / `your-first-plugin.md` / `getting-started.livemd` / `README.md` to sectioned-DSL form, write `guides/migration-spark-dsl.md`, flip ADR 0023 status to Accepted / Implementation Complete | **green** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) Follow-ups |
| [0043](0043-delete-misnamed-agent-helpers.md) | Delete `Jido.{Memory,Identity,Thread}.Agent` and `Jido.Identity.Profile` (test-only helpers that bypass the signal pipeline / violate ADR 0019). Rewrite five test callers to dispatch via `cmd/2` (production path) for writes, direct `agent.state` access for reads | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §5 + ADR 0019 enforcement |
| [0044](0044-move-rename-memory-slice.md) | Move + rename Memory slice: `lib/jido/memory/` → `lib/jido/slices/memory/`, `Jido.Memory.Slice` → `Jido.Slices.Memory`, `Jido.Memory` → `Jido.Slices.Memory.State`, `Jido.Memory.Space` → `Jido.Slices.Memory.Space`, `Jido.Memory.Actions.*` → `Jido.Slices.Memory.Actions.*` | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §1, §3 |
| [0045](0045-move-rename-identity-slice.md) | Move + rename Identity slice: `lib/jido/identity/` → `lib/jido/slices/identity/`, `Jido.Identity.Slice` → `Jido.Slices.Identity`, `Jido.Identity` → `Jido.Slices.Identity.State`, `Jido.Identity.Actions.*` → `Jido.Slices.Identity.Actions.*` | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §1, §3 |
| [0046](0046-move-rename-thread-slice.md) | Move + rename Thread slice: `lib/jido/thread/` → `lib/jido/slices/thread/`, including `Store` and store adapters; `Jido.Thread.Slice` → `Jido.Slices.Thread`, `Jido.Thread` → `Jido.Slices.Thread.State`, etc. | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §1, §3 |
| [0047](0047-move-rename-ai-react-slice.md) | Move + rename AI ReAct slice: `lib/jido/ai/{re_act,turn,tool_adapter}.ex` + `lib/jido/ai/{actions,directive}/` → `lib/jido/slices/ai_react/`. `Jido.AI.ReAct` → `Jido.Slices.AiReact`. AI ReAct directives renamed `Jido.AI.Directive.*` → `Jido.Slices.AiReact.Directives.*` (plural for consistency). `Jido.AI` facade stays put | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §1, §2, §3 |
| [0048](0048-move-rename-middlewares.md) | Move + rename built-in middlewares: `lib/jido/middleware/{retry,persister}.ex` → `lib/jido/middlewares/{retry,persister}.ex`. `Jido.Middleware.Retry` → `Jido.Middlewares.Retry`. Framework base `Jido.Middleware` (`lib/jido/middleware.ex`) stays | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §1 |
| [0049](0049-move-rename-fsm-plugin.md) | Move + rename FSM plugin: `lib/jido/plugin/fsm.ex` + `fsm/` → `lib/jido/plugins/fsm.ex` + `plugins/fsm/`. `Jido.Plugin.FSM` → `Jido.Plugins.FSM`. Framework plugin internals (`lib/jido/plugin/{config, instance, requirements, routes, schedules, spec}.ex`) stay; pod plugins stay under `lib/jido/pod/` | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §1 |
| [0050](0050-lift-framework-directives.md) | Lift framework directives to `lib/jido/directives/`; extract 9 inlined structs from `lib/jido/agent/directive.ex` into per-file modules; `Jido.Agent.Directive.*` → `Jido.Directives.*`. Pod and AI ReAct directives stay slice-scoped | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §2 |
| [0051](0051-heartbeat-telemetry-config-cleanup.md) | Move `Jido.Sensors.Heartbeat` (test-only fixture) to `test/support/`; delete `Jido.Telemetry.Config` (9 `@deprecated` shims with zero callers) | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) §5 |
| [0052](0052-docs-and-cheat-sheets-refresh.md) | Final `mix spark.cheat_sheets` regen, refresh every guide / livebook / module-doc example for the new module names, write `guides/layout.md`, flip ADR 0025 status to Accepted / Complete, update `guides/tasks/README.md` | **pending** | [ADR 0025](../adr/0025-extension-directory-layout.md) Follow-ups |
| [0053](0053-slices-as-agent-dsl-entity.md) | Lift slices into a first-class `slices do … end` agent DSL entity; agent owns the path-to-slice binding; slice modules drop `path`; actions stop redeclaring `path`; replace flat `extensions: [...]` with typed DSL block; `{Module, opts}` tuple form retired | **pending** | [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1, [ADR 0025](../adr/0025-extension-directory-layout.md) §2 |
| [0054](0054-dashboard-deps-and-scaffold.md) | Add `:phoenix`, `:phoenix_html`, `:phoenix_live_view` to mix.exs; create empty `Jido.Dashboard.*` module skeleton under `lib/jido/dashboard/`; supervise `Jido.Dashboard.Buffer` as a no-op child | **pending** | [ADR 0026](../adr/0026-redux-devtools-dashboard.md) §2 §3 |
| [0055](0055-dashboard-buffer-ets-and-ringbuffer.md) | `Jido.Dashboard.Buffer`: ETS owner GenServer for `:jido_dashboard_signals` (ordered_set, key `{agent_id, seq}`, ring-evicted at 500/agent default), lock-free per-agent sequence via `:ets.update_counter/3`, PubSub broadcast on each insert; query API `record/1`, `list/2`, `get/2`, `clear/1`, `agents/0` | **pending** | [ADR 0027](../adr/0027-dashboard-capture-and-storage.md) §3 |
| [0056](0056-dashboard-recorder-middleware.md) | `Jido.Dashboard.Middleware.Recorder` always installed in `Jido.Agent.DefaultPlugins` as the last entry; hot path `Application.get_env(:jido, {:dashboard, instance})` (~100–200 ns when off); on `:enabled`, capture `slice_after` + directives, truncate via `:erlang.external_size/1` (64 KB cap → `:truncated`), redact via `Jido.Observe.redact/2`, emit `[:jido, :dashboard, :signal, :recorded]`. Public `Jido.Dashboard` facade: `enable/1`, `disable/1`, `enabled?/1` | **pending** | [ADR 0027](../adr/0027-dashboard-capture-and-storage.md) §1 §2 §4 §5 |
| [0057](0057-dashboard-presenter-safe-terms.md) | `Jido.Dashboard.Presenter`: walk arbitrary Elixir terms producing Jason-safe, bounded output; pids/refs/funs stringify; binaries truncate over byte cap; deep maps/lists collapse over depth cap; structs without `Jason.Encoder` flatten via `inspect/2`; `stream_data` property tests | **pending** | [ADR 0027](../adr/0027-dashboard-capture-and-storage.md) §2 |
| [0058](0058-dashboard-router-and-liveviews.md) | `Jido.Dashboard.Router` macro (`jido_dashboard "/path"` Oban-Web style) + `Live.AgentList` (registry-discovered agents) + `Live.AgentDetail` (PubSub stream timeline + signal detail formatted by Presenter); inline CSS in `priv/static/jido_dashboard.css`; flips ADR 0026 to Implementation: Partial | **pending** | [ADR 0026](../adr/0026-redux-devtools-dashboard.md) §1 §3 |
| [0059](0059-dashboard-dev-runner-preview-and-docs.md) | Dev-only `Jido.Dashboard.Endpoint` (gated on `Mix.env() == :dev`) + `mix jido.dashboard --port N --host …` task; `guides/dashboard.md` (mount, redaction, opt-in toggle, multi-node note, Claude Preview workflow); `guides/dashboard.livemd` (counter agent end-to-end demo); flips ADR 0026 status to Accepted / Implementation: Partial | **pending** | [ADR 0026](../adr/0026-redux-devtools-dashboard.md) §3 |
| [0060](0060-example-showcase-app.md) | New `examples/jido_showcase/` Phoenix LiveView app with Home / Chat (LM Studio + `Jido.AI.ReAct` agent) / Pod / Multi-slice / Sensor / Dashboard pages; standalone `mix.exs` (path-deps `jido` + `req_llm`); esbuild + tailwind asset pipeline; `.claude/launch.json` for Claude Preview; one `:e2e` test asserting dashboard captures a chat turn's signals; flips ADR 0026 to Implementation: Complete | **pending** | [ADR 0026](../adr/0026-redux-devtools-dashboard.md) §6 |

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
0017 ← 0019              (docs follow-up — remove Process.sleep from livebooks; ADR 0021 enforcement)
0015 ← 0018              (ADR 0019 — per-guide example rewrites; independent of 0016/0017)

0019 ← 0021              (additive — req_llm dep + Jido.AI.* leaf modules)
0021 ← 0022              (ADR 0022 — synchronous ReAct loop uses ToolAdapter + Turn over ReqLLM.Generation)
0022 ← 0023              (ADR 0022 — signal-driven agent envelope wraps the synchronous loop)
0023 ← 0024              (ADR 0022 — livebook + local-LLM smoke test exercise the agent)

0025, 0026, 0027, 0028   (independent housekeeping; surfaced by the post-ADR 0014–0022 review)

0033 ← 0034 ← 0035 ← 0036 ← 0037 ← 0038 ← 0039 ← 0040 ← 0041 ← 0042   (ADR 0023 — Spark DSL migration; complete)
                                                  └─ ADR 0024 (schema language consolidation, decision pending — orthogonal to the chain)

0043                                              (independent — deletes test-only helpers; no rename dependency)
0044 ← 0045 ← 0046 ← 0047 ← 0048 ← 0049 ← 0050   (ADR 0025 — extension directory layout reorg; renames + moves)
0051                                              (independent — Heartbeat to test/support, Telemetry.Config deletion)
0043, 0044, 0045, 0046, 0047, 0048, 0049, 0050, 0051 ← 0052   (terminal docs/cheat-sheets refresh; flips ADR 0025 status)

0043 ← 0053                                        (ADR 0023/0025 — slices-as-DSL refactor lands after the misnamed-helpers cleanup)

0054 ← 0055, 0057                                  (ADR 0026 — scaffold first; Buffer + Presenter are the leaves)
0055, 0057 ← 0056                                  (ADR 0027 — Recorder middleware needs Buffer + Presenter)
0056 ← 0058                                        (ADR 0026 — LiveViews need real captured rows)
0058 ← 0059                                        (ADR 0026 — dev runner + guide land after the LiveViews work)
0059 ← 0060                                        (ADR 0026 — showcase consumes the documented mount story)
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
