# Task 0018 — Refresh user-facing guides for ADR 0019 strict rule

- Implements: [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) — documentation cleanup. Closes the gap between the front-and-center "Bright Line" callouts (now in `README.md`, `AGENTS.md`, `usage-rules.md`, `guides/core-loop.md`, `guides/directives.md`, and `Jido.Agent.Directive`'s moduledoc) and the per-guide example code that still references the deleted `Jido.Agent.StateOp` API.
- Depends on: [task 0012](0012-delete-state-op-directives.md) (StateOp removal — confirmed: `lib/jido/agent/state_op*` no longer exists), [task 0015](0015-strict-directives-no-runtime-state.md) (the type-system enforcement that makes the rule unambiguous to document).
- Blocks: nothing.
- Leaves tree: **green** (docs-only).

## Goal

Rewrite the stale `Jido.Agent.StateOp` examples across user-facing guides so each example compiles against current Jido and demonstrates the post-ADR 0019 contract:

- Actions mutate `agent.state` via their **return value** — a slice value at the action's declared `path:`, or `%Jido.Agent.SliceUpdate{slices: %{...}}` for cross-slice writes.
- Directives are pure I/O; emitted alongside the slice value as the third tuple element.
- No `StateOp.*` structs in directive lists. No `StateOp.SetPath` for cross-slice writes.

The currently-stamped "Heads up" banners (added in the front-and-center pass) are placeholders. This task replaces the banners with rewritten example code, then removes the banners.

## Why now

Two contradictory shapes coexist in the docs today:

- **Front doors** (`README`, `AGENTS.md`, `usage-rules.md`, `core-loop.md`, `directives.md`) present the strict rule cleanly.
- **Per-guide examples** (`agents.md`, `actions.md`, `orchestration.md`, `plugins.md`, etc.) still show `alias Jido.Agent.StateOp` and return `%StateOp.SetPath{...}` from action bodies — code that no longer compiles.

A reader who copy-pastes a snippet from `actions.md` will get a compile error referencing a module that doesn't exist. The longer this gap stays open, the more confusing the v2.0 onboarding story is.

## Files to modify

For each file, the work is the same shape: locate every `Jido.Agent.StateOp` reference (`alias`, `%StateOp.*{}` constructions, `StateOp.set_path/2`, `StateOp.set_state/1`, etc.) and rewrite the example to:

1. Drop the `alias Jido.Agent.StateOp` (or `alias Jido.Agent.{Directive, StateOp}` → `alias Jido.Agent.Directive`).
2. Replace `%StateOp.SetState{attrs: m}` / `StateOp.set_state(m)` with returning the merged slice directly: `{:ok, Map.merge(context.state, m), [...]}`.
3. Replace `%StateOp.SetPath{path: [k], value: v}` with returning the slice with `put_in` / `Map.put`: `{:ok, put_in(context.state, [k], v), [...]}`. If the path crosses slices (e.g. action declares `path: :app` but writes to `:audit`), use the **multi-slice** return: `{:ok, %Jido.Agent.SliceUpdate{slices: %{audit: new_audit}}, [...]}` and update the action's `path:` declaration to the primary slice.
4. Replace `%StateOp.ReplaceState{state: s}` with returning `s` directly (the slice value already replaces the slice in the post-deep-merge contract).
5. Replace `%StateOp.DeleteKeys{keys: ks}` / `%StateOp.DeletePath{path: p}` with `Map.drop` / `pop_in` over the slice value.
6. Then **remove the "Heads up" banner** at the top of the file (added during the front-and-center pass).

Then verify each file: snippets that pretend to be Elixir should at minimum parse, and the surrounding prose should match.

### `guides/actions.md`

- **Section to fully rewrite**: `## Return Shapes` and `### StateOps for complex updates` (around lines 76–243).
- **Concrete deliverable**: a new subsection titled "Multi-slice returns" that documents the `%Jido.Agent.SliceUpdate{slices: %{...}}` shape (per ADR 0019 §3 bucket 2) with one worked example, replacing the StateOps subsection. Keep all the simpler return-shape examples (state-only, state + directives) but verify they match the current `run/2` contract — the action signature audit in [task 0008](0008-tests-guides-adr-status.md) revealed the four-arg `run/4` contract; the guide today shows `run/2` and may need an additional update if `run/2` is no longer supported. Confirm before rewriting.
- The "Accessing State" section (lines 121+) is fine; just verify `context.state` still reflects the slice (it should, per ADR 0014's flatten).
- **Delete** the banner at line 5 once the example rewrites land.

### `guides/agents.md`

- **Audit**: `grep -n "StateOp" guides/agents.md` for every reference (`Further Reading` link at line 198 is to `state-ops.md`).
- Rewrite each StateOp snippet inline. The link to `state-ops.md` should be removed (the file is deprecated; see "state-ops.md" section below).
- **Delete** the banner at line 5.

### `guides/orchestration.md`

- **Heaviest StateOp use** outside `actions.md` — four usage sites at lines 207, 227, 403, 511 (per the audit grep).
- Each example walks through a multi-step orchestration where intermediate state (`:pending`, `:results`, `:status`) is updated. Most are within one slice and rewrite to `put_in(context.state, [:pending], remaining)` returning the new slice value. The "set pending + emit directive" pattern becomes `{:ok, %{state | pending: remaining}, [Directive.emit(signal)]}`.
- **Delete** the banner at line 3.

### `guides/plugins.md`

- **Audit**: lines 27, 36, 48, 173 from the grep. The `[:audit, :events]` SetPath at line 36 is the **canonical multi-slice case** — the plugin's middleware writes to a slice (`:audit`) that isn't its primary `path:`. Use this as the worked `%SliceUpdate{}` example.
- The text at line 173 ("the value … is written via a `%StateOp.SetPath{}` directive") needs to be rewritten to describe the new flow: actions return slices; cross-slice writes use `%SliceUpdate{}`; directives are pure I/O.
- **Delete** the banner at line 3.

### `guides/middleware.md`

- **Audit**: line 166 — the example shows middleware emitting `%StateOp.SetPath{}` directives. After ADR 0019 + ADR 0018 §1, **middleware stages state via direct `ctx.agent` mutation** instead. The example should be rewritten to show:

  ```elixir
  # Persister middleware — stage thawed state on lifecycle.starting
  def on_signal(%Signal{type: "jido.agent.lifecycle.starting"} = signal, ctx, _opts, next) do
    case Storage.thaw(ctx.agent.id) do
      {:ok, restored_agent} ->
        ctx = %{ctx | agent: restored_agent}
        next.(signal, ctx)

      {:error, _} ->
        next.(signal, ctx)
    end
  end
  ```

- Cross-reference [ADR 0018](../adr/0018-tagged-tuple-return-shape.md) §1 (the documented middleware-staging exception) and [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) §1 (the rule itself).
- **Delete** the banner at line 3.

### `guides/scheduling.md`

- **Audit**: starts around line 265. The cron-tick example shows an action that returns `[StateOp.set_state(%{processed_ticks: n})]` — rewrite to merge into the slice value: `{:ok, Map.put(context.state, :processed_ticks, n)}`.
- **Delete** the banner at line 3.

### `guides/migration.md`

- **Audit**: line 652 advice — "if you used cross-slice writes, return a `%StateOp.SetPath{path: [:other_slice, :field], value: v}`."
- This is migration advice for v1 → v2 readers. Rewrite to: "Cross-slice writes use `%Jido.Agent.SliceUpdate{slices: %{other_slice: new_value}}` returned from the action. Re-path the action to its primary slice; secondary slices listed in `slices:` are explicitly bridged." (See [ADR 0019 §3](../adr/0019-actions-mutate-state-directives-do-side-effects.md#3-multi-slice-and-cross-slice-writes).)
- **Delete** the banner at line 7.

### `guides/your-first-plugin.md`

- **Audit**: re-grep with `grep -n "StateOp" guides/your-first-plugin.md`. If the only StateOp reference was incidental (or none), simply remove the banner without rewriting.
- **Delete** the banner at line 3 once verified.

### `guides/state-ops.md`

- The whole file documents a deleted module. Two viable choices:

  **Option A (preferred): delete the file entirely.**
  - Remove `guides/state-ops.md`.
  - Search for inbound links in other guides (`grep -rn "state-ops.md" guides/ README.md AGENTS.md usage-rules.md`) and either drop the link or repoint to the relevant section in `directives.md` / `actions.md` / ADR 0019.
  - Leaves a clean directory; no historical confusion.

  **Option B: keep as a thin redirect.**
  - Replace the entire body with a one-paragraph "this guide has been removed; see [ADR 0019](adr/0019-actions-mutate-state-directives-do-side-effects.md) for the rationale and `directives.md` / `actions.md` for the replacement patterns."
  - Useful only if external bookmarks point here. Since this is a v2.0 release, there are no stable external bookmarks yet — Option A is correct.

- Pick A.

## Files not in scope

These files reference `StateOp` for legitimate historical-context reasons. **Do not modify.**

- `guides/adr/*.md` — ADRs are immutable historical decisions. They name the modules they retired.
- `guides/tasks/0012-delete-state-op-directives.md` — task spec for the deletion itself.
- `guides/tasks/0010-pod-runtime-signal-driven-state-machine.md`, `0009-pod-mutate-cast-await-api.md`, `0003-retire-strategy-port-fsm.md`, `0008-tests-guides-adr-status.md`, `0004-middleware-pipeline.md`, `0005-migrate-intree-plugins.md` — task specs reference StateOp as their starting state.
- `guides/review-findings-adrs-0014-0016.md`, `guides/review-findings-round-2.md` — round-of-review artifacts; historical record of what the audit found.

## Files to delete

- `guides/state-ops.md` (per Option A above).

## Files to create

- None.

## Tests

Docs-only; no test changes required. However, two manual verification steps:

1. **Snippet round-trip**: pick one rewritten example from each modified guide, paste into a scratch IEx session against the current `lib/`, and confirm it compiles + produces the documented behavior. Catches typos in the rewrite.

2. **Cross-link sanity**: after rewrites land, every link from a user-facing guide to `state-ops.md` is dead (file is deleted). Run:

   ```bash
   grep -rn "state-ops" guides/ README.md AGENTS.md usage-rules.md
   ```

   Hits should appear only in `tasks/`, `adr/`, or `review-findings-*` (out-of-scope historical files). Any other hit is a stale link to fix.

## Acceptance

- `grep -rn "Jido\.Agent\.StateOp\|alias Jido\.Agent\.StateOp\|%StateOp\." guides/agents.md guides/actions.md guides/orchestration.md guides/plugins.md guides/middleware.md guides/scheduling.md guides/migration.md guides/your-first-plugin.md` returns **zero hits**.
- `guides/state-ops.md` does not exist.
- The "Heads up" banners added in the front-and-center pass are removed from each file (since the contradiction they flagged is resolved).
- Every example in the modified guides demonstrates one of: (a) action returns slice value at `path:`, (b) action returns `%Jido.Agent.SliceUpdate{slices: %{...}}` for multi-slice, (c) middleware stages `ctx.agent` directly per ADR 0018 §1.
- No example in a user-facing guide returns a `StateOp` struct from an action.
- `mix docs` builds clean (cross-references resolve).
- `mix test` still green (sanity — no code changed).

## Out of scope

- **Adding new examples or features.** Strict like-for-like rewrite; same scenarios, new shape.
- **Updating ADRs / task docs / review-findings.** Historical artifacts; leave as-is.
- **Tightening the front-door docs further.** Already done in the front-and-center pass; this task is the per-guide cleanup that follows.
- **Rewriting the `run/2` vs `run/4` contract documentation.** If the audit reveals `actions.md` shows the wrong arity, surface it but don't fix it here — that belongs in a separate task that owns the action-signature documentation across `actions.md`, `agents.md`, and the `Jido.Action` moduledoc together.
- **Reviewing the `Jido.Action` moduledoc, `Jido.Agent` moduledoc, etc., for stale StateOp references.** Likely also stale, but module docs are a separate sweep — call them out as a follow-up if found.

## Risks

- **Multi-slice rewrites may need code awareness.** When an example crossed slices via `StateOp.SetPath`, picking the right "primary slice" for the action's new `path:` requires understanding the action's intent. If unclear, prefer the **signal-cascade** option (ADR 0019 §3 bucket 3) — emit a signal that another action handles — over guessing the multi-slice shape.

- **`actions.md`'s `run/2` signature.** The four-arg `run/4` contract from [task 0000](0000-inline-action-ctx-threading.md) is the post-v2.0 shape. If the guide still documents `run/2`, that's a separate doc-rot problem that's deeper than just StateOp. Decide before starting: rewrite to `run/4` everywhere, or scope this task narrowly to StateOp removal and file the arity rewrite as 0017. Recommend scoping narrowly — pick one rewrite shape and stick to it.

- **`middleware.md`'s Persister example.** The "stage thawed state on `lifecycle.starting`" pattern is real and important — getting the rewrite wrong here is worse than leaving the banner. Cross-check against `lib/jido/middleware/persister.ex` (or wherever the Persister actually lives) before authoring the new snippet; do not write speculative code.

- **`state-ops.md` link rot.** Deleting the file may break links from external blog posts, ecosystem-package READMEs, etc. Since v2.0 hasn't shipped publicly, the blast radius is the in-repo guides only — but verify no hexdocs / `package.exs` / `mix.exs` doc config explicitly lists the file before deleting.

- **Banner removal happens last.** If a rewrite gets blocked mid-task, leave the banner in place — better an outdated banner than a fresh contradiction.
