---
name: Task 0056 — `Jido.Dashboard.Middleware.Recorder` + `Jido.Dashboard` facade (`enable/1`, `disable/1`, `enabled?/1`)
description: Implement the always-installed, runtime-toggleable middleware that captures `slice_after` + directives per cmd. Add it to `Jido.Agent.DefaultPlugins` so every `use Jido.Agent` agent has it as the **last** entry in its chain. Hot path: one `Application.get_env(:jido, {:dashboard, instance})` lookup; if not `:enabled`, return immediately. Otherwise build the row, truncate via `:erlang.external_size/1` (default cap 64 KB → `:truncated` marker), redact via `Jido.Observe.redact/2`, emit `[:jido, :dashboard, :signal, :recorded]`. The `Buffer` GenServer attaches to that event at boot and broadcasts on PubSub. Public facade `Jido.Dashboard.{enable,disable,enabled?}/1` wraps `Application.put_env/delete_env/get_env`. Tests stand up a real `AgentServer` with a tiny test agent and verify (a) baseline overhead under 1 µs/signal disabled, (b) toggle takes effect mid-run with no restart, (c) Buffer sees expected signal rows in order.
---

# Task 0056 — Recorder middleware and dashboard facade

- Implements: [ADR 0027](../adr/0027-dashboard-capture-and-storage.md) §1 §2 §4 §5; closes ADR 0027 to **Implementation: Complete**.
- Depends on: [task 0054](0054-dashboard-deps-and-scaffold.md), [task 0055](0055-dashboard-buffer-ets-and-ringbuffer.md), [task 0057](0057-dashboard-presenter-safe-terms.md) (the Recorder calls the Presenter when capturing).
- Blocks: [task 0058](0058-dashboard-router-and-liveviews.md), [task 0059](0059-dashboard-dev-runner-preview-and-docs.md), [task 0060](0060-example-showcase-app.md).
- Leaves tree: **green**.

## Context

This is the keystone task for the dashboard's capture pipeline. After
this commit, every `use Jido.Agent` agent has the dashboard
middleware in its chain by default; flipping
`Jido.Dashboard.enable(MyApp.Jido)` at runtime turns capture on for
that instance with no agent restart and no global GC pause.

Two hard correctness requirements:

1. **The disabled hot path must be cheap.** One Application env read,
   nothing else. No allocation, no log line, no telemetry emit. The
   acceptance bench (< 1 µs/signal added overhead when disabled) is
   load-bearing — if we can't hit it, the design is wrong, not the
   implementation.
2. **Capture must observe `slice_after` deterministically.** The
   middleware sits at the **tail** of the chain so any prior
   middleware that mutates state has settled before we read. Any
   middleware inserted *after* the Recorder will produce stale
   dashboard rows; this is documented, not enforced.

## Files to modify

### `lib/jido/dashboard.ex`

Replace the task 0054 stub with the public facade:

```elixir
defmodule Jido.Dashboard do
  @moduledoc """
  …
  """

  @spec enable(atom()) :: :ok
  def enable(instance) when is_atom(instance) do
    Application.put_env(:jido, {:dashboard, instance}, :enabled)
  end

  @spec disable(atom()) :: :ok
  def disable(instance) when is_atom(instance) do
    Application.delete_env(:jido, {:dashboard, instance})
  end

  @spec enabled?(atom()) :: boolean()
  def enabled?(instance) when is_atom(instance) do
    Application.get_env(:jido, {:dashboard, instance}) == :enabled
  end
end
```

Three functions, no surprises. The reason this is a facade and not
just calls scattered through user code is so the implementation can
move (e.g. to ETS) without API churn.

### `lib/jido/dashboard/middleware/recorder.ex`

Replace the task 0054 stub with the real middleware. Use the
post-[ADR 0014](../adr/0014-slice-middleware-plugin.md) middleware
shape (`on_signal(signal, ctx, opts, next) :: {ctx, [directive]}`).

Pseudocode for the hot path:

```elixir
def on_signal(signal, ctx, _opts, next) do
  case Application.get_env(:jido, {:dashboard, ctx.instance}) do
    :enabled ->
      ts_before = System.monotonic_time(:nanosecond)
      slice_before_size = :erlang.external_size(ctx.agent.state[ctx.slice_path])
      {ctx_after, directives} = next.(signal, ctx)
      ts_after = System.monotonic_time(:nanosecond)

      slice_after = ctx_after.agent.state[ctx_after.slice_path]
      record_async(ctx, signal, slice_after, directives, ts_after - ts_before, slice_before_size)
      {ctx_after, directives}

    _ ->
      next.(signal, ctx)
  end
end
```

`record_async/6` builds the row, calls
[`Jido.Dashboard.Presenter`](0057-dashboard-presenter-safe-terms.md)
on `signal`, `slice_after`, and `directives`, applies size
truncation via `:erlang.external_size/1` (default 64 KB,
configurable via `:jido, :dashboard_size_cap`), and emits
`[:jido, :dashboard, :signal, :recorded]` via
`:telemetry.execute/3` with the row as metadata. Sequence number
generation is in the Buffer; the Recorder doesn't know about `seq`.

The "async" in `record_async` is naming, not an actual `Task` —
keeping the work synchronous in the cmd path is fine because (a)
the Presenter + truncate is microseconds and (b) any concurrency
needs are met by the Buffer's lock-free ETS writes. We're not
spawning processes per signal.

Field redaction: per
[ADR 0027 §5](../adr/0027-dashboard-capture-and-storage.md), call
`Jido.Observe.redact/2` on the row using the same
`:redact_sensitive` config flag. Reuse, don't reinvent.

### `lib/jido/dashboard/buffer.ex`

Add the telemetry handler attach. In `Buffer.init/1`:

```elixir
:telemetry.attach(
  "jido-dashboard-buffer",
  [:jido, :dashboard, :signal, :recorded],
  &__MODULE__.handle_signal_event/4,
  []
)
```

`handle_signal_event/4` calls `record/1` with the metadata. This
runs in the emitting process (the cmd / agent process); insertion
into ETS is from there, not from the Buffer GenServer.

### `lib/jido/agent/default_plugins.ex` (or whatever the post-ADR-0023 home is)

Add `Jido.Dashboard.Middleware.Recorder` to the default middleware
chain as the **last** entry. If `DefaultPlugins` exposes a list,
append; if it's a function, append in the function's return.
Existing tests for `DefaultPlugins` need updating to expect the
extra entry.

If [ADR 0025](../adr/0025-extension-directory-layout.md)'s rename
moved this module to a new path (`lib/jido/agent/default_plugins.ex`
→ `lib/jido/plugins/defaults.ex` or similar), follow that — task
0055 lands after the 0043-0052 reorg sequence has rebased through.

## Files to create

### `test/jido/dashboard/recorder_test.exs`

Cover:

1. **Middleware behaviour conformance.** `on_signal/4` returns
   `{ctx, directives}`. With dashboard disabled, `ctx_after` is
   exactly what `next.(signal, ctx)` returned — no mutation.
2. **Disabled hot path overhead.** Microbenchmark:
   `:timer.tc/3` over 10 000 calls to `on_signal/4` with a `next`
   that returns `{ctx, []}` immediately, dashboard disabled.
   Average overhead added by Recorder must be < 1 µs/call. Skip
   the assertion in CI if `:os.type()` indicates a slow runner;
   keep it as a sanity check locally.
3. **Enable mid-run.** Boot a `Jido.AgentServer` with a tiny test
   agent. Send 5 signals; Buffer should be empty.
   `Jido.Dashboard.enable(test_instance)`. Send 5 more signals;
   `Buffer.list/2` should show exactly the second batch's signals
   in order, with `slice_after` matching the agent state at each
   step.
4. **Disable mid-run.** Reverse of (3). After
   `Jido.Dashboard.disable/1`, no further rows are recorded.
5. **Truncation marker.** Push a signal whose `slice_after` is a
   2 MB binary. The recorded row's `slice_after` collapses to a
   `:truncated` marker; the row's `truncated:` field lists
   `[:slice_after]`; the row still records normally.
6. **Redaction.** With
   `config :jido, :observability, redact_sensitive: true` and a
   `password` key in `slice_after`, the recorded row has
   `[REDACTED]` in that position.
7. **`on_exit/1` cleanup.** Each test calls
   `Application.delete_env(:jido, {:dashboard, test_instance})`
   in `on_exit/1`, plus
   `Jido.Dashboard.Buffer.clear(agent_id)`. Verify with a
   second test that no state from a prior test leaks.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --min-priority higher` clean.
- `mix dialyzer` clean.
- `mix test` green, including the new test file.
- `mix test --include e2e` green.
- Disabled-path microbench: < 1 µs/call added overhead. Capture the
  number in the commit message (`BENCH: Recorder.on_signal/4
  disabled overhead = N ns/call on M iterations`).
- Manual smoke: from `iex -S mix`, build a tiny agent, enable the
  dashboard, send a signal, and read the row back via
  `Jido.Dashboard.Buffer.list/2`. The row's `slice_after` matches
  the agent's slice value after the cmd.
- Flip `ADR 0027` front matter from
  `Implementation: Pending` to `Implementation: Complete`. Update
  the `guides/adr/README.md` index row.

## Out of scope

- LiveViews / Router / asset wiring — task 0058.
- Dev runner / `mix jido.dashboard` task / dashboard guide /
  livebook — task 0059.
- Example showcase app — task 0060.
- Multi-node fan-out, persistence beyond ETS, time-travel
  re-execution — explicitly out of scope per
  [ADR 0026](../adr/0026-redux-devtools-dashboard.md) and
  [ADR 0027](../adr/0027-dashboard-capture-and-storage.md).
- A Spark verifier that asserts `Recorder` is the last middleware
  in the chain. Documented contract for v1; revisit if users hit it.

## Risks

- **Default-plugins ordering invariant.** Recorder must be last.
  If a future task adds another middleware to `DefaultPlugins`
  without checking ordering, the dashboard quietly shows stale
  state. Mitigation: a comment in `default_plugins.ex` near the
  Recorder line, and a test in `recorder_test.exs` that asserts
  `DefaultPlugins.list() |> List.last() == Jido.Dashboard.Middleware.Recorder`.
- **Capture during error paths.** When the cmd returns
  `{:error, reason}`, the row's `ok?` is `false` and `error` carries
  the reason. The Recorder must not raise on its own — any
  exception inside `record_async/6` is caught and logged at
  `:warning`, then swallowed. Capture failures must never break
  signal handling.
- **Test-suite leakage from `Application.put_env`.** Tests must
  clean up. Without it, a test that flipped `enable/1` will leak
  to other tests sharing the instance atom. The pattern is in the
  test acceptance above and in
  [ADR 0027 §5](../adr/0027-dashboard-capture-and-storage.md).
- **Hot-path budget regression.** Any future change that adds work
  inside the disabled-path branch (e.g. logging the toggle state,
  reading more env keys) blows the < 1 µs budget. Keep the
  benchmark in `recorder_test.exs` so regressions surface in CI.
- **Telemetry handler global handler ID.** `:telemetry.attach/4`
  uses string IDs; if the Buffer is restarted (supervisor crash),
  re-attach must succeed. Use `:telemetry.attach/4`'s
  `{:error, :already_exists}` return to detach-then-reattach in
  `init/1`. Standard pattern.
- **`slice_path` of `nil`.** Multi-slice agents
  ([ADR 0014](../adr/0014-slice-middleware-plugin.md)) carry the
  current slice path on the ctx. If a signal pre-routing has no
  resolved slice (e.g. broadcast signals), `slice_path` is `nil`
  and `slice_after` records as `nil`. Document; don't fail the
  capture.
