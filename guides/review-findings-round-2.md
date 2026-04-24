# Second review — ADRs 0014–0016 docs (plan + tasks)

Follow-up /review of [plan](~/.claude/plans/atomic-whistling-graham.md), [tasks/](tasks/), and first-round [findings](review-findings-adrs-0014-0016.md). All prior round-1 findings are marked ✅ or deferred; round-2 focuses on **drift between decisions and doc text**, plus a few unresolved gaps.

Status key: **✅ resolved** / **🔄 in discussion** / **⏸ pending**

---

## Stale-language drift (decision made, text not updated)

### D1 — Plan file still references `lib/jido/middleware/persister.ex` as new file — ✅ resolved

[atomic-whistling-graham.md:217](~/.claude/plans/atomic-whistling-graham.md) critical-files table row:

> New: `lib/jido/slice.ex`, `lib/jido/middleware.ex`, **`lib/jido/middleware/persister.ex`**, **`lib/jido/middleware/log_errors.ex`**, **`lib/jido/middleware/stop_on_error.ex`**, `lib/jido/plugin/fsm.ex`

Three stale entries per W7 + S6 resolution:
- Persister moved to `lib/jido/plugin/persister.ex` (Plugin, not Middleware)
- LogErrors & StopOnError dropped entirely
- Missing: `lib/jido/middleware/retry.ex`, `lib/jido/agent/directive/thaw.ex`, `lib/jido/agent/directive/hibernate.ex`, `lib/jido/plugin/persister/thaw.ex`, `lib/jido/plugin/persister/hibernate.ex`

### D2 — Plan C4 section still lists LogErrors / StopOnError / Persister as middleware — ✅ resolved

[atomic-whistling-graham.md:132-136](~/.claude/plans/atomic-whistling-graham.md):

> New middleware modules under `lib/jido/middleware/`:
> - `lib/jido/middleware/persister.ex` — default behaviour: …
> - `lib/jido/middleware/log_errors.ex` — …
> - `lib/jido/middleware/stop_on_error.ex` — …

Decisions lines 17 + S6 already overrode this. Should list only `lib/jido/middleware/retry.ex` under C4; Persister is C5.

### D3 — Plan C6 still wires Persister via `Options.middleware:` — ✅ resolved

[atomic-whistling-graham.md:163](~/.claude/plans/atomic-whistling-graham.md):

> `instance_manager.ex:382-402`: delete `maybe_thaw/3`; … Instead pass `middleware: [{Jido.Middleware.Persister, %{…}}]` via the new `Options.middleware:` field.

Should be `plugins: [{Jido.Plugin.Persister, %{…}}]` via `Options.plugins:`. The up-top decision at line 42 is correct; the C6 section wasn't updated.

### D4 — Plan C6 Options changes list is incomplete — ✅ resolved

[atomic-whistling-graham.md:166](~/.claude/plans/atomic-whistling-graham.md): "Add `middleware:` option" — also needs `plugins:` option per refined W7.

### D5 — Plan critical-files table: `await.ex` row is stale — ✅ resolved

[atomic-whistling-graham.md:208](~/.claude/plans/atomic-whistling-graham.md): `lib/jido/await.ex | Rewired as thin wrappers (C7)` — should be `Deleted (C7)` per W6.

### D6 — Plan verification step 2 references `Jido.Middleware.Persister` — ✅ resolved

[atomic-whistling-graham.md:231](~/.claude/plans/atomic-whistling-graham.md): "Attach `Jido.Middleware.Persister`; hibernate + thaw…" — should be `Jido.Plugin.Persister`.

### D7 — `tasks/README.md` row for 0004 lists retired middlewares — ✅ resolved

[tasks/README.md:13](tasks/README.md): "Single-tier middleware pipeline; retire legacy plugin hooks; **Persister / LogErrors / StopOnError**"

Should be: "Single-tier middleware pipeline; retire legacy plugin hooks; ship Retry middleware". Persister moved to 0005; LogErrors/StopOnError dropped.

### D8 — Task 0002 commit number typo — ✅ resolved

[tasks/0002-flatten-agent-state-path-required.md:3](tasks/0002-flatten-agent-state-path-required.md:3): "Commit #: 2 of 8" — should be "2 of 9" (C0 added; all other tasks say "of 9").

### D9 — Task 0004 goal blurb + leaves-tree refer to dropped modules / dissolved shim — ✅ resolved

[tasks/0004-middleware-pipeline.md:7](tasks/0004-middleware-pipeline.md:7): "in-tree plugins still use **Legacy** until C5" — the Legacy shim was dissolved per W1. Should read "in-tree plugins still use the old `Jido.Plugin` macro until C5".

[tasks/0004-middleware-pipeline.md:11-13](tasks/0004-middleware-pipeline.md:11): "Ship a **minimal standard middleware library to cover the retired capabilities**" — `Retry` doesn't cover the retired `error_policy` capability; migration-guide self-roll snippet does. Rephrase to "Ship `Jido.Middleware.Retry`; error-handling replacement deferred to follow-up PR".

### D10 — Task 0005 `Jido.Middleware.Persister` references (transforms config) — ✅ resolved

Three spots in [tasks/0005-migrate-intree-plugins.md](tasks/0005-migrate-intree-plugins.md) still use the old module name:

- [line 60](tasks/0005-migrate-intree-plugins.md:60): "persistence shape is handled by `Jido.Middleware.Persister` config"
- [line 80](tasks/0005-migrate-intree-plugins.md:80): config block `{Jido.Middleware.Persister, %{…}}`
- [line 355](tasks/0005-migrate-intree-plugins.md:355): "referenced by the agent's Persister middleware config. Called by `Jido.Middleware.Persister`"

Should all be `Jido.Plugin.Persister`. (Line 199 correctly reflects the refinement: "replacing the earlier idea of a `Jido.Middleware.Persister` module.")

### D11 — Task 0006 `init/1` sketch missing `options.plugins` — ✅ resolved

Resolved by switching to `build_middleware_chain(agent_module, options)` — takes the full `Options` struct, extracts `.middleware` and `.plugins` internally. Applied to C4 and C6 sketches.

[tasks/0006-lifecycle-signals-collapse-thaw.md:105](tasks/0006-lifecycle-signals-collapse-thaw.md:105): `chain <- build_middleware_chain(agent_module, options.middleware)` — 2-arg call.

C4's sketch uses 3 args including `options.plugins` ([tasks/0004-middleware-pipeline.md:31](tasks/0004-middleware-pipeline.md:31)). Should match.

### D12 — Task 0006 pre-amble lists storage/persistence_key as Options fields — ✅ resolved

[tasks/0006-lifecycle-signals-collapse-thaw.md:91-96](tasks/0006-lifecycle-signals-collapse-thaw.md:91): "InstanceManager passes only the storage config and persistence key. … `storage:` — `{adapter, opts}` tuple, optional. `persistence_key:` — …"

Reads like Options still has these fields; per W7 they move entirely into `{Jido.Plugin.Persister, %{storage: …, persistence_key: …}}` inside `Options.plugins:`. Later section (line 163) correctly says "Remove `storage:`, `persistence_key:`, `restored_from_storage:`." — pre-amble disagrees with itself.

### D13 — Task 0006 risks reference dropped `LogErrors` / `StopOnError` — ✅ resolved

[tasks/0006-lifecycle-signals-collapse-thaw.md:218](tasks/0006-lifecycle-signals-collapse-thaw.md:218): "Verify the middleware chain with `Jido.Middleware.LogErrors` + `StopOnError` enabled during start"

Both dropped per S6. Either delete the risk entry or reword to describe the check without referencing retired modules.

### D14 — Task 0007 acceptance criterion references deleted `Jido.Await` — ✅ resolved

[tasks/0007-ack-subscribe-primitives.md:291](tasks/0007-ack-subscribe-primitives.md:291):

> `Jido.Await.completion/3` returns a shape identical to before on a straightforward case (agent reaches `:completed` in its declared path).

The module is deleted in this same commit. Delete the bullet, or replace with a test against the user-defined `MyApp.Await` example pattern from the migration guide.

### D15 — Task 0007 risks section still contains "Await.completion dispatch" — ✅ resolved

[tasks/0007-ack-subscribe-primitives.md:318](tasks/0007-ack-subscribe-primitives.md:318): risk describes "the subscribe-based rewrite" of Await, but there's no rewrite — the module is deleted. Delete this risk bullet.

### D16 — Task 0008 ReAct purpose paragraphs dangle after deferral — ✅ resolved

[tasks/0008-tests-guides-adr-status.md:81-89](tasks/0008-tests-guides-adr-status.md:81): the "deferred to follow-up PR" paragraphs start at 81, but lines 87-89 are stale hold-over text ("Purpose: demonstrate the combo shape… Roughly 200-300 lines") describing the original, non-deferred plan. Delete 87-89.

### D17 — Task 0008 test rewrites reference `Jido.Middleware.Persister` — ✅ resolved

Two lines still point at the old module name:

- [tasks/0008-tests-guides-adr-status.md:50](tasks/0008-tests-guides-adr-status.md:50): "rewrite against `Jido.Middleware.Persister`" → `Jido.Plugin.Persister`
- [tasks/0008-tests-guides-adr-status.md:73](tasks/0008-tests-guides-adr-status.md:73): test path `test/jido/middleware/persister_test.exs` → `test/jido/plugin/persister_test.exs`

### D18 — Task 0008 ADR hash count — ✅ resolved

[tasks/0008-tests-guides-adr-status.md:141](tasks/0008-tests-guides-adr-status.md:141): "Fill `Related commits:` with **the eight hashes** from this PR." — nine commits now (C0–C8). Should say "nine hashes".

---

## Gaps and potential issues

### G1 — `Agent.new/1` extension phasing unclear — ✅ resolved

**(a)** C4 adds the `Options.plugins:` schema field and wires it into the chain builder only. State seeding via Agent.new/1 config auto-merge is deferred to C5, since that's when in-tree plugins gain `path/0`.

**(b)** Approach (ii) — AgentServer.init/1 pre-merges runtime plugin configs into `initial_state` before calling `agent_module.new/1`. `new/1`'s signature is untouched. Documented in C5.

C4 adds `Options.plugins:` ([tasks/0004-middleware-pipeline.md:154-155](tasks/0004-middleware-pipeline.md:154)) and states: "`Agent.new/1` treats them the same as compile-time `agent_module.plugins()` — registers slice, seeds state from config auto-merge."

But:
- C4's `init/1` sketch ([line 34](tasks/0004-middleware-pipeline.md:34)) calls `agent_module.new(id: options.id, state: options.initial_state)` — does NOT pass `options.plugins`.
- C5 says "Agent.new/1 extension needed … Extend it in this commit to also accept plugin-slice keys in the state map" ([tasks/0005-migrate-intree-plugins.md:195](tasks/0005-migrate-intree-plugins.md:195)).

Two questions:
- **(a)** Does C4 wire runtime-injected plugins into `Agent.new/1` at all, or does that wiring land in C5? If C5, then `Options.plugins:` added in C4 has no effect at C4 (fine, since tree is red C2-C7 and no runtime tests exercise the path yet). Clarify.
- **(b)** How does `Agent.new/1` learn about `options.plugins`? Either (i) `agent_module.new(..., additional_plugins: options.plugins)`, or (ii) init/1 pre-merges plugin config into `initial_state` before calling `new/1`. Neither task spells out the handoff. Pick one and document.

### G2 — Runtime vs compile-time plugin config precedence when the same module appears in both — ✅ resolved

Per the "error on duplicate" rule (W7): compile-time + runtime declarations of the same module raise at init. This means two mutually exclusive ownership patterns per agent module: (a) compile-time Persister (standalone / tests), or (b) runtime Persister via InstanceManager (pooled, per-instance config). Documented in C4 risks and C6 InstanceManager section; migration guide (C8) flags it.

Per W7 resolution: `agent_module.plugins() ++ options.plugins` with duplicate-module-in-chain check raising at init. Fine. But **what the task docs don't state**: if a user declares `{Jido.Plugin.Persister, config_a}` at compile time AND InstanceManager injects `{Jido.Plugin.Persister, config_b}` at runtime, does the system raise, or does runtime win?

Per the stated rule (error on duplicate) — raises. Which means InstanceManager users MUST NOT compile-time-declare Persister. Doc this explicitly in C4 risks or C6 (InstanceManager integration).

### G3 — ADRs 0014 / 0015 describe pre-refinement architecture — ✅ resolved

Approach (β) — inline-edit ADR body to match shipped reality, with an "Alternatives considered" addendum for the rejected shape. Updated in both 0014 and 0015: Persister rewritten as a Plugin, example uses `plugins:` not `middleware:`, chain sketch drops Logger, error-policy line reworded to note only `Retry` ships with explicit deferral of `LogErrors`/`StopOnError`/`Logger`/`CircuitBreaker`. Two new alternatives entries capture the Persister-as-middleware and error-handling-middleware-in-this-PR rejections.

ADRs 0014 and 0015 describe `Jido.Middleware.Persister` as a middleware module and list `LogErrors`/`StopOnError` in the standard library. C8 flips them to Implemented but doesn't rewrite their body text. Readers hitting the implemented ADRs will see a description that doesn't match shipped code.

Options:
- **(α)** Add an "Implementation refinements" addendum section to each ADR describing the divergences (Persister is Plugin not Middleware; LogErrors/StopOnError dropped; Options.plugins + Options.middleware added).
- **(β)** Inline-edit the ADR text to match shipped reality, losing the ADR-as-record-of-proposed-design property.
- **(γ)** Leave ADRs describing the proposed design; point to the migration guide + code for the actual shape.

Needs a choice in C8.

### G4 — Emission sequencing of identity signals outside init/1 — ✅ resolved

Added one-line clarification to task 0002: `parent_died` and `orphaned` emit through `state.middleware_chain` (same chain built at init), just like lifecycle signals. No special runtime-vs-init-time emission path.

SS3 resolution covers `lifecycle.starting` + `identity.partition_assigned` at init/1. But `identity.parent_died` and `identity.orphaned` (per [tasks/0002-flatten-agent-state-path-required.md:59-60](tasks/0002-flatten-agent-state-path-required.md:59)) emit from the parent-DOWN handler at runtime. The task doc doesn't explicitly state they route through `state.middleware_chain`. They should — otherwise middleware can't observe them. Minor clarification needed.

### G5 — `emit_through_chain` helper ambiguity across C4 / C6 / C7 — ✅ resolved

Open-code the ctx→state merge as `%{state | agent: new_ctx.agent}` everywhere. Updated C7 to match C4 and C6 — no named helper; the one-liner speaks for itself.

Three tasks sketch the chain-invoke + execute-directives + sync pattern:

- [C4:140-143](tasks/0004-middleware-pipeline.md:140): `state_with_agent = %{state | agent: new_ctx.agent}`
- [C6:55-61](tasks/0006-lifecycle-signals-collapse-thaw.md:55): `emit_through_chain/2` uses the same `%{state | agent: new_ctx.agent}`
- [C7:307-313](tasks/0007-ack-subscribe-primitives.md:307): uses `state_from_ctx(new_ctx)` — a different helper name not defined elsewhere

Pick one name (`sync_state_from_ctx/2` or similar) and define it once, reference from the other tasks.

### G6 — C2 migration pass doesn't cover user-plugin legacy `state_key:` atoms — ✅ resolved

Not applicable. Per ADR 0014 this is a rewrite, not a migration — no external users exist, and no migration obligation to external plugin authors. The "migration pass" language in C2 is a misnomer; it's really just "translate in-tree fixtures and local dev checkpoints to the new shape." No migration-guide bullet needed for custom plugins.

**Follow-on question**: if there's no migration obligation at all, is the `Persist.thaw/3` migration pass worth shipping? It exists to keep in-tree tests' stored checkpoints working across the refactor, but those fixtures could equally be regenerated. Worth considering whether C2's migration pass + its dedicated tests are load-bearing, or can be replaced with "regenerate fixtures."

[tasks/0002-flatten-agent-state-path-required.md:76-83](tasks/0002-flatten-agent-state-path-required.md:76): migration map hardcodes in-tree plugin keys (`:__thread__` → `:thread`, etc.). External users with their own `state_key: :__foo__` plugins won't have their on-disk data migrated.

Since ADR 0014 already says "No external users exist," this might be by design. But the migration guide should explicitly state: "if you defined a custom plugin with `state_key: :__your_key__`, checkpoints from before this migration contain keys we don't automatically rename. Hand-migrate on thaw via …".

Low priority; flag as documentation gap.

---

## Summary

All findings are **stale-language drift** (D1-D18) and **under-specified edges** (G1-G6), not blocking bugs. The plan and task docs are executable as-is, but anyone reading them cold will hit contradictions (e.g., Persister described three different ways across the docs).

| Type | Count | Severity |
|---|---|---|
| D — stale language | 18 | low, but polluting |
| G — unresolved gap | 6 | medium (G1, G3 actually need decisions) |

Biggest actually-substantive items:
- **G1**: who passes `options.plugins` into `Agent.new/1` and when.
- **G3**: disposition of ADR 0014/0015 body text at "Implemented" flip.
- **G2**: compile-time+runtime-both-declared-Persister semantics.
