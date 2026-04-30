---
name: Task 0051 — Move `Jido.Sensors.Heartbeat` to `test/support/`; delete `Jido.Telemetry.Config` deprecations
description: Two small cleanups surfaced by the post-ADR-0025 sweep, neither blocking but worth folding into the same chain so the tree is clean. (1) `Jido.Sensors.Heartbeat` is a test fixture parked in `lib/jido/sensors/heartbeat_sensor.ex` — its only callers are `test/jido/sensor/runtime_test.exs`. Move it to `test/support/` where `test_actions.ex`, `test_agents.ex`, etc. already live. (2) `Jido.Telemetry.Config` is 9 `@deprecated` shim functions pointing at `Jido.Observe.Config.*` with **zero callers** anywhere. Per the "NO LEGACY ADAPTERS" rule in `guides/tasks/README.md`, delete them.
---

# Task 0051 — Move `Jido.Sensors.Heartbeat` to `test/support/`; delete `Jido.Telemetry.Config` deprecations

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §5 (companion cleanups).
- Depends on: nothing (independent of the rename chain).
- Blocks: nothing.
- Leaves tree: **green**.

## Context

A second pass against ADR 0019 and the "NO LEGACY ADAPTERS" rule
(captured in [`guides/tasks/README.md`](README.md)) surfaced two
small cleanups:

### 1. `Jido.Sensors.Heartbeat` is a test fixture in `lib/`

`lib/jido/sensors/heartbeat_sensor.ex` defines a `use Jido.Sensor`
that emits heartbeat signals at configurable intervals. Its
moduledoc reads as a documentation example. Its only callers are
in `test/jido/sensor/runtime_test.exs` — the sensor runtime test
uses it as a fixture to exercise the sensor lifecycle.

Test fixtures belong in `test/support/`, alongside the existing
`test_actions.ex`, `test_agents.ex`, `signal_collector.ex`,
`scheduler_integration_harness.ex`, etc. Today the test compile path
already includes `test/support/` (verified — adapters live there).

### 2. `Jido.Telemetry.Config` is 9 dead `@deprecated` functions

`lib/jido/telemetry/config.ex` contains nine `@deprecated`
forwarding functions, each pointing at the `Jido.Observe.Config.*`
equivalent:

```elixir
@deprecated "Use Jido.Observe.Config.telemetry_log_level/1 instead"
def telemetry_log_level(opts), do: Jido.Observe.Config.telemetry_log_level(opts)
```

`git grep -n 'Jido\.Telemetry\.Config\.'` across `lib/`, `test/`,
`guides/`, `livebooks/` returns **zero hits** outside the file
itself. The deprecation pathway exists for a migration that already
completed; nothing in tree consumes the old API.

The "NO LEGACY ADAPTERS" rule in `guides/tasks/README.md` is
explicit: "When a task says 'rewrite X to Y', **rewrite it**. Do
not write a shim, a `__before_compile__` adapter, a translation
layer, …" The `Jido.Telemetry.Config` shim is a holdover from a
prior migration; per the rule, delete it.

## Goal

After this commit:

- `lib/jido/sensors/heartbeat_sensor.ex` does not exist.
- `test/support/heartbeat_sensor.ex` exists, defining
  `Jido.Sensors.Heartbeat` (module name unchanged — keeps the test
  references stable).
- `lib/jido/telemetry/config.ex` does not exist (or, if any
  non-deprecated function still has a caller, only the 9 deprecated
  functions are removed).

## Approach

### Move Heartbeat to test/support

```sh
git mv lib/jido/sensors/heartbeat_sensor.ex test/support/heartbeat_sensor.ex
```

Module name stays `Jido.Sensors.Heartbeat`. The
`test/jido/sensor/runtime_test.exs` references do not change.

Verify `test/support/` is on the test compile path. Mix's
`elixirc_paths/1` callback in `mix.exs` typically reads:

```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_),     do: ["lib"]
```

If that's already the shape, the move is complete and the test
compiles. If `test/support` isn't on the path, add it.

### Check `lib/jido/sensors/`

After the move, if `lib/jido/sensors/` only contained
`heartbeat_sensor.ex` and `bus_sensor.ex`, it now contains only
`bus_sensor.ex`. Confirm `bus_sensor.ex` has actual production
callers:

```sh
git grep -nE 'Jido\.Sensors\.BusSensor|Jido\.Sensors\.Bus\b' lib/ test/ guides/ livebooks/
```

If `bus_sensor.ex` is also test-only, move it too as part of this
task; if it has production callers, leave it.

### Delete `Jido.Telemetry.Config`

```sh
git rm lib/jido/telemetry/config.ex
```

If after the deletion `lib/jido/telemetry/` contains only
`formatter.ex` (or other production code), the directory survives.
If the deletion empties the directory, `rmdir` it.

`git grep -nE 'Jido\.Telemetry\.Config\b'` post-deletion returns
zero hits — confirmed in advance, so this is just a verification
check.

The companion `lib/jido/telemetry.ex` (`Jido.Telemetry`) and the
`@telemetry` event emission code are **untouched** — only the
deprecated `Config` shim goes away.

## Files to delete

- `lib/jido/telemetry/config.ex` — `Jido.Telemetry.Config`.

## Files to move

- `lib/jido/sensors/heartbeat_sensor.ex` → `test/support/heartbeat_sensor.ex`.

## Files to modify

### `mix.exs` (only if needed)

Confirm `elixirc_paths(:test)` includes `"test/support"`. Add if
missing. Today's `test/support/` already has compiled fixtures, so
likely no change needed.

### `test/jido/sensor/runtime_test.exs`

No source change — `Jido.Sensors.Heartbeat` module name is unchanged,
and the test compile path picks up the moved file.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean — `test/jido/sensor/runtime_test.exs` still
  passes; the heartbeat-sensor integration tests still find the
  module.
- `mix test --include e2e` clean.
- `mix docs` builds clean — `Jido.Telemetry.Config` was indexed by
  ExDoc; after deletion the index updates with no dead links.
- `git grep -nE 'Jido\.Telemetry\.Config\b'` returns zero hits across
  the repo.
- `lib/jido/sensors/heartbeat_sensor.ex` does not exist;
  `test/support/heartbeat_sensor.ex` does.

## Out of scope

- Other "test fixtures parked in lib/" candidates beyond Heartbeat.
  None surfaced in the audit; if more appear later, separate task.
- `Jido.Telemetry` (the non-deprecated module) and its event
  emission. Not touched.
- `lib/jido/sensors/bus_sensor.ex` unless it's test-only too (audit
  before moving). If it stays in `lib/`, this task does not touch it.

## Risks

- **`test/support/` is not on the test compile path.** Symptom: the
  sensor runtime test fails with `Jido.Sensors.Heartbeat is not
  loaded`. Fix: add `"test/support"` to `elixirc_paths(:test)` in
  `mix.exs`. Today's `test/support/` already compiles
  `failing_time_zone_database.ex` etc., so this is presumably
  configured — but verify before assuming.
- **A docstring elsewhere references `Jido.Sensors.Heartbeat` as an
  example.** If `guides/sensors.md` (or similar) uses Heartbeat as
  the user-facing example, the move makes the doc reference dangling.
  Either keep Heartbeat in `lib/` (revising this task to "delete the
  deprecation only"), or refactor the guide to point at a different
  example. Recommendation: spot-check `guides/` before the move; if
  Heartbeat is documented as a user example, write a tiny
  "MyApp.HeartbeatSensor" inline in the guide instead.
- **`mix dialyzer` produces a warning about an unreferenced
  `@deprecated`.** Should not happen — Dialyzer is fine with
  `@deprecated` attribute, only with actual unused functions.
  Re-run after the deletion to confirm.
