---
name: Task 0066 — Decide and execute the `Jido.Plugin` abstraction question
description: After [task 0064](0064-classify-and-relocate-pod-bus-plugin.md) lands, `Jido.Plugin` has zero in-tree users — every former plugin (FSM, BusPlugin) was reclassified as a pure `use Jido.Slice` because none of them implemented middleware behaviour. The Plugin abstraction (`Jido.Plugin` = `Jido.Slice` + `@behaviour Jido.Middleware`, in one module) is conceptually valid but currently unexercised. This task makes a binding decision — keep, with an in-tree smoke fixture so the path stops rotting; or deprecate, removing the DSL machinery (`Jido.Plugin`, `Jido.Dsl.Plugin`, `Jido.Dsl.Plugin.Info`, `Jido.Plugin.Routes`, `Jido.Plugin.Instance`, `Jido.Plugin.Spec`, `Jido.Plugin.Requirements`, `Jido.Plugin.Config`) plus the plugin-classifying branch of `Jido.Dsl.Agent.Transformers.WalkExtensions.classify_mount/2`, and collapsing the four-extension-shape vocabulary (slice / middleware / plugin / directive) to three. The decision needs to weigh the conceptual cleanness of "one module = slice + middleware behaviour" against the maintenance cost of a Spark DSL surface, an info module, an instance shape, and a transformer branch with no in-tree exercise — plus the question of whether anyone outside the tree actually mounts a plugin (signal: check tags / migration history / external feedback before pulling).
---

# Task 0066 — Decide and execute the `Jido.Plugin` abstraction question

- Implements: closes the open question raised at the end of
  [task 0064](0064-classify-and-relocate-pod-bus-plugin.md) §"Open question".
- Depends on: [task 0064](0064-classify-and-relocate-pod-bus-plugin.md).
- Blocks: [task 0067](0067-migration-notes-rename-chain.md) (migration notes
  need to know whether `Jido.Plugin` survives or is deprecated to write the
  right copy).
- Leaves tree: **green**.

## Context

After task 0064, `lib/jido/plugin.ex` exposes a Spark DSL extension
(`use Jido.Plugin` ⇒ `use Jido.Slice` + `@behaviour Jido.Middleware`) that has
**zero in-tree users**. The audit grep:

```sh
rg -nP "^  use Jido\.Plugin\b" lib/
# (empty after task 0064)
```

The supporting machinery is non-trivial:

| File                              | Lines (approx) | Purpose                                            |
| --------------------------------- | -------------- | -------------------------------------------------- |
| `lib/jido/plugin.ex`              | ~80            | `use Jido.Plugin` macro entry point                |
| `lib/jido/dsl/plugin.ex`          | ~60            | Spark DSL extension declaration                    |
| `lib/jido/dsl/plugin/info.ex`     | ~70            | Introspection (delegates to `Jido.Dsl.Slice.Info`) |
| `lib/jido/plugin/instance.ex`     | ~80            | Mount-instance struct + constructor                |
| `lib/jido/plugin/spec.ex`         | ~80            | Compile-time spec for plugin-action fan-out        |
| `lib/jido/plugin/routes.ex`       | ~50            | Route prefix expansion (shared with Slice)         |
| `lib/jido/plugin/requirements.ex` | ~50            | `requirements:` keyword validation                 |
| `lib/jido/plugin/config.ex`       | ~120           | Config-merge plumbing for plugin instances         |

Plus a branch in `lib/jido/dsl/agent/transformers/walk_extensions.ex:214–235`:

```elixir
plugin? = Spark.Dsl.is?(module, Jido.Plugin)
slice?  = Spark.Dsl.is?(module, Jido.Slice)

if plugin? do
  {:plugin, PluginInstance.new({module, config}, path)}
else
  {:slice, SliceInstance.new({module, config}, path)}
end
```

And parallel persistence/lookup paths (`:plugin_instances` vs
`:slice_instances`, `Jido.Dsl.Agent.Info.plugin_instances/1` vs
`slice_instances/1`, separate `plugin_paths` / `slice_paths` lists, etc.) in
`lib/jido/dsl/agent/info.ex` and `lib/jido/middlewares/persister.ex`.

Carrying this for one untested code path is a real cost — code that nothing
exercises rots silently as the surrounding DSL and runtime evolve.

The conceptual case for keeping: a module that's stateful (slice) AND wraps the
signal pipeline (middleware) is a real pattern. It's how a "tracing slice" or
"rate-limiting slice that also tracks call counts" might be written. Just no
built-in extension currently exercises it.

## The decision

**This task is decision-first, code-second.** Step 1 produces a written
recommendation; step 2 implements whichever path the recommendation picks. Do
not skip step 1 — pulling out a public DSL extension without writing down why is
the kind of decision that gets re-litigated every six months.

### Step 1 — Write the decision (deliverable: ADR or task-internal note)

Answer four questions:

1. **Is anyone outside the tree mounting a `use Jido.Plugin` module?** Signals:
   search the project's recent issue tracker / discussion / commit history for
   external user references; check the public README for plugin examples; check
   `guides/migration-spark-dsl.md` for plugin-migration wording. If we can't
   tell, default to "yes, possibly" — the abstraction is documented, so absence
   of evidence is not evidence of absence.

2. **Does any planned future extension want the combined shape?** Concrete
   candidates: rate-limiting middleware that also tracks per-target counters
   (slice state); tracing middleware that holds an in-memory ring buffer per
   agent (slice state). If at least one is on the realistic roadmap, keep the
   abstraction.

3. **What does keeping cost monthly?** Maintenance is approximately:
   - Compile-time keep-up when the slice DSL changes (Plugin re-uses Slice
     internals, so most slice work flows through automatically).
   - The `walk_extensions.ex:classify_mount/2` branch and the parallel
     persistence keys.
   - One paragraph in every guide that lists the four extension shapes.

4. **What does removing cost?**
   - Hard break for any external user mounting `Jido.Plugin`. Reversibility is
     low — once `Jido.Plugin` is gone, restoring it means re-implementing the
     DSL extension.
   - Documentation rewrite from "four shapes" to "three shapes" across guides,
     ADRs, cheat sheets.

### Step 2A — If KEEP

1. Add a fixture under `test/support/` (NOT `lib/`) that uses `use Jido.Plugin`
   and exercises both halves: a slice schema with state, a
   `signal_routes do … end` block, AND a `Jido.Middleware` `call/4` impl that
   does something observable (e.g., increments a counter in slice state).
2. Add an integration test that mounts the fixture on a host agent, sends a
   signal, and asserts both: (a) state-update from the slice half lands, and (b)
   the middleware half's `call/4` ran (e.g., the counter incremented).
3. Document in `guides/slices.md` (or wherever the four-shape vocabulary lives)
   that Plugin = Slice + Middleware-behaviour, with one paragraph pointing at
   the fixture as canonical reference.
4. Add a verifier or compile-time warning when a `use Jido.Plugin` module has no
   `@impl Jido.Middleware` callback — that catches the "accidentally a slice"
   case automatically going forward, so future contributors don't reproduce the
   BusPlugin / FSM situation.

### Step 2B — If DEPRECATE

1. Mark `Jido.Plugin` `@deprecated "Use `use Jido.Slice`and add`@behaviour
   Jido.Middleware` directly. See guides/migration-spark-dsl.md."` and emit a
   compile-time warning.
2. Phase A — add the deprecation, ship a minor release. (Stops the bleeding
   without breaking anyone.)
3. Phase B — in a subsequent release, delete:
   - `lib/jido/plugin.ex`, `lib/jido/dsl/plugin.ex`,
     `lib/jido/dsl/plugin/info.ex`,
     `lib/jido/plugin/{instance,spec,routes,requirements,config}.ex`.
   - The `:plugin` branch of `WalkExtensions.classify_mount/2`.
   - `Jido.Dsl.Agent.Info.plugin_instances/1` and the persisted
     `:plugin_instances` / `:plugin_paths` / `:plugin_specs` keys.
   - References in `Jido.Middlewares.Persister`, `Jido.Slices.ChildBus`'s
     `fetch_routes/1` (drops the `Jido.Plugin` branch, keeps only Slice).
   - The four-shape vocabulary in guides becomes three-shape.
4. Update `guides/migration-spark-dsl.md` with the rewrite recipe — the
   migration is straightforward because every former plugin's slice DSL is
   already what `use Jido.Slice` provides; users only need to add
   `@behaviour Jido.Middleware` and the corresponding `def call/4` impl.

## Acceptance criteria

- [ ] Step 1 written down (~½ page) — keep-or-deprecate decision with the four
      questions answered, committed under `guides/adr/` if it warrants ADR-level
      recording, otherwise as a `## Decision` section appended to this task
      file.
- [ ] If KEEP: smoke fixture under `test/support/`, integration test asserting
      both halves run, guides paragraph, optional verifier warning for
      plugin-without-middleware-callbacks.
- [ ] If DEPRECATE Phase A: `@deprecated` annotation in `lib/jido/plugin.ex`,
      compile-time warning fires when a downstream `use Jido.Plugin` compiles,
      migration recipe in `guides/migration-spark-dsl.md`.
- [ ] If DEPRECATE Phase B (separate task / commit): the eight files listed
      above are gone; audit grep `rg -nP "Jido\.Plugin\b" lib/` returns only
      framework-internal references that survive the rename.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] `mix test` passes.

## Out of scope

- The migration-notes consolidation (covered by
  [task 0067](0067-migration-notes-rename-chain.md), which itself depends on
  this task's decision so it knows whether to write "renamed" or "removed" copy
  for `Jido.Plugin`).
- The `Jido.Pod.Plugin` reference still floating in older ADR / task docs.
  Already a no-op (`Jido.Pod.Plugin` doesn't exist post-task-0061), but
  individual documentation files can be cleaned up incrementally as they're
  touched, not in a sweep.

## Decision

**DEPRECATE and remove.** Recorded in
[ADR 0028](../adr/0028-deprecate-jido-plugin.md). Execution lives in
[task 0068](0068-remove-jido-plugin.md).

The four audit questions resolved as:

1. **External users?** The abstraction is documented (plugins.md,
   your-first-plugin.md, layout.md) and the package is at v2.2.0 on Hex, so
   "yes, possibly" is the right default. The decision accepts this as a hard
   break released under v3.0.0 with a one-line migration recipe.

2. **Future extensions wanting the combined shape?** ADR 0014's deferred
   follow-ups (`CircuitBreaker`, `LogErrors`, `StopOnError`, `Logger`) and the
   speculative tracing/rate-limiting candidates all resolve cleanly as either
   middleware-only or `use Jido.Slice` + `@behaviour Jido.Middleware`. None
   require a separate extension shape.

3. **Cost of keeping?** ~800 LOC across eight framework files plus a parallel
   persistence vocabulary (`:plugin_instances`, `:plugin_specs`,
   `:plugin_paths`, `:validated_plugin_routes`, `:expanded_plugin_routes`,
   `:expanded_plugin_schedules`, `:all_plugin_routes`) and a classifier branch
   in `WalkExtensions.classify_mount/2` — all currently with zero production
   callers. The audit confirmed even the mount-layer features Plugin appeared to
   provide over Slice (`as:` aliasing, `route_prefix`,
   `Application.get_env(otp_app, mod)` config merge, runtime `requires:`
   validation) have no in-tree exercise outside Plugin's own self-tests.

4. **Cost of removing?** Hard break for any external user mounting
   `Jido.Plugin`. Migration is mechanical: `use Jido.Plugin` →
   `use Jido.Slice` + `@behaviour Jido.Middleware` + add the module to the
   agent's `middleware: […]` list. Documentation rewrite from "four shapes" to
   "three shapes" across guides, ADRs, cheat sheets.

Step 2A (KEEP path) is **not** executed. Step 2B (DEPRECATE) is implemented in a
single phase by task 0068 — there is no observable external Plugin adoption that
would benefit from a multi-release deprecation window, and the parallel
persistence vocabulary should not have to be maintained through one.
