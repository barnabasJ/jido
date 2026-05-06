---
name: Task 0068 — Remove `Jido.Plugin` from the framework
description:
  Execute the deprecation decided in [ADR
  0028](../adr/0028-deprecate-jido-plugin.md). Delete `lib/jido/plugin.ex`,
  `lib/jido/plugin/`, `lib/jido/dsl/plugin.ex`, `lib/jido/dsl/plugin/`. Strip
  the `:plugin_*` parallel persistence vocabulary and classifier branch from the
  agent transformer pipeline. Migrate or delete every test that uses `use
  Jido.Plugin`. Collapse the four-shape extension vocabulary in the guides to
  three. Land the migration recipe (`use Jido.Plugin` → `use Jido.Slice` +
  `@behaviour Jido.Middleware` + explicit `middleware:` registration) in
  `guides/migration-spark-dsl.md` and `guides/migration.md`.
---

# Task 0068 — Remove `Jido.Plugin` from the framework

- Implements: [ADR 0028](../adr/0028-deprecate-jido-plugin.md).
- Depends on: [task 0066](0066-decide-jido-plugin-abstraction.md) (decision).
- Blocks: [task 0067](0067-migration-notes-rename-chain.md) (migration notes can
  now write "removed" copy for `Jido.Plugin`).
- Leaves tree: **green**.

## Context

After tasks 0064 (BusPlugin → ChildBus slice) and 0065 (Pod → slice),
`Jido.Plugin` has zero in-tree users. The audit in task 0066 confirmed the
abstraction's mount-layer features (`as:` aliasing, `route_prefix`,
`Application.get_env(otp_app, mod)` config merge, runtime `requires:`
validation) also have zero production callers — they're exercised only by
Plugin's own self-tests. ADR 0028 records the decision to delete the abstraction
entirely. This task is the execution.

The package is at v2.2.0; this removal is a breaking change and the next release
bumps to v3.0.0. Migration for any external `use Jido.Plugin` user is
mechanical:

```elixir
# Before
defmodule MyOrg.Plugins.RateLimiter do
  use Jido.Plugin
  slice do … end
  signal_routes do … end
  @impl Jido.Middleware
  def call(signal, _opts, _ctx, next), do: next.(signal)
end

# After
defmodule MyOrg.Slices.RateLimiter do
  use Jido.Slice
  @behaviour Jido.Middleware
  slice do … end
  signal_routes do … end
  @impl Jido.Middleware
  def call(signal, _opts, _ctx, next), do: next.(signal)
end
```

…and on the host agent, mount the module under `slices do … end` AND add it to
`middleware: [...]`. The auto-mounting that Plugin did is replaced by an
explicit middleware registration.

## Execution

Order matters: tests/fixtures first → transformer surgery → file deletions →
docs → verify. After every step, `mix compile --warnings-as-errors` and
`mix test` must pass.

### Step 1 — Migrate fixtures and tests off `use Jido.Plugin`

Each fixture below uses `use Jido.Plugin` but does NOT implement
`Jido.Middleware` callbacks. Convert in place to `use Jido.Slice`. Where the
test name embeds "plugin", rename to "slice" in the same commit:

- `test/support/test_agents.ex:101-128` — `TestPluginWithRoutes` and
  `TestPluginWithPriority` become bare slices. Rename to `TestSliceWithRoutes` /
  `TestSliceWithPriority` and update `AgentWithPluginRoutes` accordingly.
- `test/jido/integration/scheduler_integration_test.exs:42`
- `test/jido/integration/scheduler_durability_integration_test.exs:52`
- `test/jido/agent/slices_attachment_test.exs:63`
- `test/jido/agent/multi_instance_fan_out_test.exs:56`
- `test/jido/pod_test.exs:20, 41`
- `test/jido/agent_server/agent_server_test.exs:1101`
- `test/jido/agent_server/signal_router_test.exs:35, 49`
- `test/jido/agent_server/plugin_subscriptions_test.exs` →
  `test/jido/agent_server/slice_subscriptions_test.exs`
- `test/jido/agent_server/plugin_children_test.exs` →
  `test/jido/agent_server/slice_children_test.exs`
- `test/examples/react/react_plugin_test.exs` — rename or merge into the
  existing slice test
- `test/jido/agent_plugin_integration_test.exs` →
  `test/jido/agent_slice_integration_test.exs`

### Step 2 — Delete Plugin-only test files

These exercise the abstraction itself; nothing to migrate:

- `test/jido/dsl/plugin_test.exs`
- `test/jido/plugin/plugin_test.exs`
- `test/jido/plugin/instance_test.exs`
- `test/jido/plugin/routes_test.exs`
- `test/jido/plugin/config_test.exs`
- `test/jido/plugin/requirements_test.exs`
- `test/jido/plugin/schedules_test.exs`
- `test/examples/plugins/plugin_basics_test.exs` (and the
  `test/examples/plugins/` directory if empty after)

After step 2, `mix test` must still pass — Plugin machinery is still in `lib/`,
just no longer exercised.

### Step 3 — Strip Plugin branches from agent transformers and verifiers

- `lib/jido/dsl/agent/transformers/walk_extensions.ex`
  - Remove `alias Jido.Dsl.Plugin.Info, as: PluginInfo` (line 30) and any other
    `Jido.Plugin*` aliases.
  - In `classify_mount/2` (lines 214–235): remove the
    `Spark.Dsl.is?(module, Jido.Plugin)` branch; the slice-only path becomes the
    only path. Update the error message to drop `or use Jido.Plugin`.
  - Drop the persists of `:plugin_instances` (line 112), `:plugin_specs` (line
    115), `:plugin_paths` (line 117).
  - Update the moduledoc to drop the `:plugin_instances` bullet.
- `lib/jido/dsl/agent/transformers/expand_routes.ex` — drop `:plugin_instances`
  read (line 33), `expanded_plugin_routes` (lines 36, 79),
  `expanded_plugin_schedules` (lines 42, 81), `validated_plugin_routes` (lines
  14, 65), `all_plugin_routes` (lines 58, 83), and all calls to
  `Jido.Plugin.Routes.expand_routes/1`, `Jido.Plugin.Routes.detect_conflicts/1`,
  `Jido.Plugin.Schedules.expand_schedules/1`,
  `Jido.Plugin.Schedules.schedule_routes/1`. Slice-only path remains.
- `lib/jido/dsl/agent/transformers/validate_requirements.ex` — drop the
  `:plugin_instances` read (line 20). If validation logic only applied to
  plugins, drop entirely. If it should generalise to slices (Slice already
  declares `requires`), lift it; otherwise note the regression in the task
  notes.
- `lib/jido/dsl/agent/transformers/generate_accessors.ex` — drop the
  `:plugin_instances` read (line 28).
- `lib/jido/dsl/agent/transformers/merge_schemas.ex` — drop the `:plugin_specs`
  read (line 21).
- `lib/jido/dsl/agent/verifiers/unique_paths.ex` — drop the `:plugin_paths` read
  (line 15); operate on `:slice_paths` only.

### Step 4 — Strip Plugin from Info and runtime consumers

- `lib/jido/dsl/agent/info.ex` — remove `plugin_instances/1` (71),
  `plugin_specs/1` (81), `plugin_paths/1` (86), `plugin_routes/1` (110),
  `plugin_schedules/1` (123), `plugin_config/2` (166), `plugin_state/3` (197),
  `plugins/1` (52). Each was reading a `:plugin_*` persisted key that no longer
  exists after step 3.
- `lib/jido/middlewares/persister.ex:151-154` — drop the `plugin_targets` block
  calling `Info.plugin_instances/1`. Update the line-8 docstring to say "slice
  modules" not "slice/plugin modules".
- `lib/jido/slices/child_bus/auto_subscribe_child.ex:71-82` — `fetch_routes/1`
  collapses to one arm: `Spark.Dsl.is?(child_module, Jido.Slice)` →
  `Jido.Dsl.Slice.Info.signal_routes(child_module)`; the error message drops
  `or Jido.Plugin`.
- `lib/jido/agent_server.ex:2058-2061` — remove
  `defp plugin_middleware_halves/1` stub and any caller. The C5-wiring comment
  becomes obsolete.
- `lib/jido/igniter/templates.ex:86` — remove the plugin generator template;
  `mix jido.gen.plugin` is no longer offered.

### Step 5 — Delete the Plugin module tree

- `lib/jido/plugin.ex`
- `lib/jido/plugin/config.ex`
- `lib/jido/plugin/instance.ex`
- `lib/jido/plugin/requirements.ex`
- `lib/jido/plugin/routes.ex`
- `lib/jido/plugin/schedules.ex`
- `lib/jido/plugin/spec.ex`
- `lib/jido/plugin/` (directory)
- `lib/jido/dsl/plugin.ex`
- `lib/jido/dsl/plugin/info.ex`
- `lib/jido/dsl/plugin/` (directory)

After step 5, `rg -nP "Jido\.Plugin\b" lib/` returns zero hits.

### Step 6 — Documentation

Delete:

- `guides/plugins.md`
- `guides/your-first-plugin.md`
- `guides/plugins.livemd`

Edit (collapse "four extension surfaces" → three):

- `guides/layout.md:8-27, 100-101, 129` — remove the "fourth surface — plugins"
  paragraph; drop the `Plugin` row from the naming table; drop "plugins" from
  the out-of-tree mirror list.
- `guides/slices.md:13-14` — remove the cross-ref to `Jido.Plugin`.
- `guides/middleware.md:8` — change "Slice / Middleware / Plugin model" to
  "Slice / Middleware model".
- `guides/discovery.md:26` — drop `use Jido.Plugin` from the auto-indexed list.
- `guides/agents.md:34-37` — remove Plugin from the extensions list.
- `guides/signals.md` — search and remove any Plugin references.
- `guides/migration-spark-dsl.md:146, 264-271` — replace with the migration
  recipe (see top of this file).
- `guides/migration.md` — add a "Migrating from `Jido.Plugin`" section with the
  same recipe.
- `guides/review-findings-round-2.md`,
  `guides/review-findings-adrs-0014-0016.md` — review notes, leave alone
  (historical).

ADR statuses (no body rewrite; add a one-line note under the existing Status
header pointing at ADR 0028):

- `guides/adr/0011-retire-strategy-plugins-are-control-flow.md`
- `guides/adr/0013-slices-middleware-plugins.md`
- `guides/adr/0014-slice-middleware-plugin.md` (was Status: Implemented; the
  Plugin third tier is being undone — annotate accordingly)
- `guides/adr/0023-spark-dsl-and-registerable-extensions.md`
- `guides/adr/0025-extension-directory-layout.md`
- `guides/adr/0025-amendment-slices-as-agent-dsl-entity.md`

### Step 7 — Verify

- `rg -nP "Jido\.Plugin\b" lib/` → zero hits.
- `rg -nP "use Jido\.Plugin\b" test/` → zero hits.
- `rg -nP ":plugin_instances|:plugin_specs|:plugin_paths|:validated_plugin_routes|:expanded_plugin_routes|:expanded_plugin_schedules|:all_plugin_routes" lib/`
  → zero hits.
- `mix compile --warnings-as-errors` clean.
- `mix test` passes (whole suite, including renamed slice/middleware tests).

## Acceptance criteria

- [ ] `lib/jido/plugin.ex`, `lib/jido/plugin/`, `lib/jido/dsl/plugin.ex`,
      `lib/jido/dsl/plugin/` are gone.
- [ ] No `:plugin_*` persistence keys remain in the agent transformer pipeline.
- [ ] `Jido.Dsl.Agent.Info` no longer exposes any `plugin_*` accessor.
- [ ] `Jido.Slices.ChildBus.AutoSubscribeChild.fetch_routes/1` has one arm (the
      Slice arm).
- [ ] No test under `test/` calls `use Jido.Plugin`; Plugin-only test files are
      deleted; renamed test files use slice/middleware terminology.
- [ ] Guides describe three extension surfaces, not four. `plugins.md`,
      `your-first-plugin.md`, `plugins.livemd` are deleted.
- [ ] Migration recipe is in `guides/migration-spark-dsl.md` and
      `guides/migration.md`.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] `mix test` passes.

## Out of scope

- v3.0.0 release packaging (CHANGELOG entry, `hex.publish`) — handled in a
  separate release task.
- A backward-compat shim aliasing `Jido.Plugin` to
  `use Jido.Slice + @behaviour Jido.Middleware`. Explicitly rejected by
  ADR 0028.
- Generalising slice `requires:` to actually run validation at agent compile
  time. Plugin had `Jido.Plugin.Requirements.validate_all/2`; Slice declares the
  section but has no validator. If desired, lift in a separate task — this task
  only restores parity (neither validates).
- Lifting `Jido.Plugin.Routes.detect_conflicts/1` (multi-mount route conflict
  detection) into a slice-side transformer. Read it before deleting; if the
  logic is worth porting, file a follow-up task.
- Wiring `otp_app` runtime config resolution into Slice. With Plugin gone,
  `otp_app` in the slice DSL is informational only — no runtime call to
  `Application.get_env`. The field stays in the schema for introspection.

## Notes for the implementer

- The renames in step 1 are the largest source of churn. Do them in their own
  commit (or commits) before any code surgery, so the test suite stays green
  through the rename and the subsequent surgery sees clean baselines.
- Step 3 must complete before step 4, and step 4 before step 5 — the
  transformers persist the keys, the Info functions read them, and the Plugin
  modules are referenced by both. Reverse order would break compile.
- Step 6 (docs) can be done in parallel with steps 3–5 if helpful, but the
  ADR-status annotations should land in the same commit as the code deletions so
  the historical record stays consistent.
