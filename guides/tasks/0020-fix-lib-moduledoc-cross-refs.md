---
name: Task 0020 — Fix lib/ moduledoc cross-references caught by `mix docs`
description: Surface and fix the small set of lib/ moduledoc warnings ex_doc emits — wrong-relative-path ADR links and unqualified `Agent.*` function refs — that surfaced while running `mix docs` during task 0018. Mechanical edits, no semantics change. Sets up a clean baseline so future moduledoc warnings stand out.
---

# Task 0020 — Fix lib/ moduledoc cross-references caught by `mix docs`

- Implements: documentation hygiene follow-up to [task 0018](0018-refresh-user-guides-for-adr-0019.md). The build was clean from a "tests pass" angle while task 0018 was in flight, but `mix docs` emits a long list of cross-reference warnings; a small number of them are unambiguous typos in lib/ moduledocs that the docs-only task 0018 wasn't allowed to touch.
- Depends on: nothing. Independent housekeeping.
- Blocks: nothing. The warnings being addressed don't break the docs build — they just clutter it.
- Leaves tree: **green**.

## Goal

`mix docs` currently emits ~40 cross-reference warnings. The vast majority are guide-level (cross-links between extras files that ex_doc can't resolve, or genuine dead links to files that no longer exist) and need design judgment to fix. A small subset live in lib/ moduledocs and are mechanical typos:

1. **Wrong-relative-path ADR links in `lib/jido/agent.ex`.** Two occurrences of `[ADR 0018](../adr/0018-tagged-tuple-return-shape.md)` — the relative path is broken (resolves to `lib/jido/adr/`, which doesn't exist). Every other lib/ ADR link uses `../../guides/adr/...`, which is the correct shape from a `lib/jido/<file>.ex` source location.

2. **Unqualified `Agent.new/1` / `Agent.cmd/2` references in lib/ moduledocs.** Six occurrences across five files. ex_doc resolves function references against `@spec`s in the doc set, so an unqualified `Agent.new/1` looks for `Agent.new/1` (no such module) — the fix is `Jido.Agent.new/1`. Same shape across the rest. Once qualified, ex_doc renders them as live cross-references.

3. **`Jido.Plugin.Routes.expand_route/2` reference in `lib/jido/pod/bus_plugin.ex:32`.** The function is private (`defp expand_route/2` lives in `lib/jido/plugin/routes.ex:186`); the public API is `Jido.Plugin.Routes.expand_routes/1` (note the trailing `s`, takes a `%Plugin.Instance{}`). The docstring is pointing readers at the wrong arity and access modifier. Re-aim at `expand_routes/1` and adjust the prose.

These fixes silence ~10 of the ~40 `mix docs` warnings, all in lib/. None of them change runtime behavior; the test suite stays green. The point is to bring the lib/ portion of the build to zero warnings so the remaining 30 (guide-level) warnings are easier to triage in a follow-up.

## Files to modify

For each file the work is mechanical: locate the cited reference, replace with the correct form, run `mix docs` to confirm the warning disappears.

### `lib/jido/agent.ex`

Two occurrences of `[ADR 0018](../adr/0018-tagged-tuple-return-shape.md)` — lines 21 (in the `@moduledoc`) and 824 (inside the `cmd/2` `@doc` of the generated module).

```diff
- See [ADR 0018](../adr/0018-tagged-tuple-return-shape.md).
+ See [ADR 0018](../../guides/adr/0018-tagged-tuple-return-shape.md).
```

`replace_all` is safe — both occurrences want the same fix.

### `lib/jido/agent/path_conflict_error.ex`

Line 3: ``Raised at `Agent.new/1` when two declared slices share the same `path:` —`` → ``Raised at `Jido.Agent.new/1` when two declared slices share the same `path:` —``.

### `lib/jido/agent/slice_validation_error.ex`

Line 3: ``Raised at `Agent.new/1` when a slice's seeded value fails schema`` → ``Raised at `Jido.Agent.new/1` when a slice's seeded value fails schema``.

### `lib/jido/pod.ex`

Line 103: ``canonical topology before delegating to the base `Agent.new/1`. User`` → ``canonical topology before delegating to the base `Jido.Agent.new/1`. User``.

### `lib/jido/pod/plugin.ex`

Line 15: ``state: %{pod: %{topology: ..., topology_version: ...}}` to `Agent.new/1`.`` → use `Jido.Agent.new/1`.

### `lib/jido/plugin/fsm.ex`

Line 24: ``Agent.new/1`:`` → ``Jido.Agent.new/1`:``.

### `lib/jido/agent_server.ex`

Line 38 (inside the `@moduledoc` ASCII flow diagram): `→ routing → Agent.cmd/2 → {agent, directives}` → `→ routing → Jido.Agent.cmd/2 → {agent, directives}`.

### `lib/jido/pod/bus_plugin.ex`

Line 32: ``see `Jido.Plugin.Routes.expand_route/2`, which leaves `jido.*` routes`` — the public API is `expand_routes/1`. Re-aim and adjust prose:

```diff
- see `Jido.Plugin.Routes.expand_route/2`, which leaves `jido.*` routes
+ see `Jido.Plugin.Routes.expand_routes/1`, which leaves `jido.*` routes
```

Confirm the surrounding paragraph still reads coherently after the rename — `expand_routes/1` operates on a whole `%Plugin.Instance{}` rather than a single route, so prose phrased around "the route expansion call" should still parse correctly. If it doesn't, broaden the rewrite to the full sentence.

## Files to create

None.

## Files to delete

None.

## Tests

No code changes — behavioral tests don't apply. Verification is the `mix docs` warning delta.

## Acceptance

- `mix docs 2>&1 | grep -c "warning:"` drops by ~10 relative to pre-task baseline. Capture the before/after counts in the commit message.
- `mix docs 2>&1 | grep '"Agent.new/1"\|"Agent.cmd/2"\|"Jido.Plugin.Routes.expand_route/2"'` returns zero lines.
- `mix docs 2>&1 | grep '"../adr/0018'` returns zero lines (the fixed agent.ex paths no longer point at `lib/adr/`).
- `mix test` is green — no behavior changed.
- `git diff main -- guides/` is empty (this task touches lib/ only).
- The remaining `mix docs` warnings (guide-level dead links, ADR cross-refs from `.md` files) survive untouched — they belong to task 0021 below.

## Out of scope

- **Guide-level dead-link warnings.** Multiple guides reference `await.md`, `strategies.md`, several livebooks (`slices.livemd`, `middleware.livemd`, `plugins.livemd`, `pods.livemd`, `cron-children-lifecycle.livemd`, `observability.livemd`, `actions-and-directives.livemd`, `call-cast-await-subscribe.livemd`, `fsm-strategy.livemd`) that don't exist. Each is either a stale reference (file was renamed/deleted) or a forward reference to a file that was planned but never landed. Fixing them requires per-link decisions ("rename to X", "remove the reference", "create the missing file"), not a sweep — file as task 0021 if the noise is worth eradicating.

- **Guide-to-ADR cross-references.** ~12 warnings are guide markdown files linking to `adr/00NN-...md`. The links resolve correctly on the filesystem; ex_doc warns because the ADR files aren't in the `extras` list in `mix.exs`. Adding them would silence the warnings but expand the published doc set significantly. Either accept the warnings as ex_doc noise, or add ADRs to `extras` as a deliberate decision — separate task.

- **`Jido.await/2`, `Jido.await_child/4`, `Jido.get_children/1` doc references in guides.** These functions don't exist on the `Jido` module today; the matching APIs live elsewhere (e.g. `Jido.Exec.await/2`, `Jido.AgentServer.await_child/3`). Either the API was consolidated and the guides are stale, or the umbrella `Jido.*` re-exports never landed. Either resolution is bigger than a typo fix — defer.

- **Doctest indentation warning at `lib/jido/pod.ex:189`.** Looks like a real doctest formatting issue, not a cross-reference. Investigate separately if it's actually a failing doctest vs. a cosmetic warning.

## Risks

- **`expand_route/2` rename may surface a wrong intent.** The original docstring at `lib/jido/pod/bus_plugin.ex:32` may have meant to describe the route-expansion *behavior* (single-route shape) and just used the wrong function name. Reading the surrounding paragraph — including what "the call" or "this function" refers to in context — should disambiguate. If the prose actually wanted to point at the private `expand_route/2`, the fix is to rephrase the prose around the public surface, not to expose the private helper. Confirm by reading the full paragraph before patching.

- **Bulk `replace_all` on `Agent.new/1` is unsafe across lib/.** Strings like `MyAgent.new/1` (intentional placeholder for "your agent module") MUST stay unqualified — they're examples, not cross-references. Use targeted `Edit` per file, scoped to the moduledoc context. The grep `grep -rn "Agent\.new/1\|Agent\.set/2\|Agent\.cmd/" lib/ | grep -v "MyAgent\." | grep -v "Jido\.Agent\."` returns the exact set to fix.

- **`mix docs` emits warnings on stderr and exits 0.** Don't gate the acceptance check on a non-zero exit — count the `"warning:"` lines instead. The surrounding `\x{2502}` and `\x{2514}` UTF-8 box-drawing characters in the warning output don't affect the grep.
