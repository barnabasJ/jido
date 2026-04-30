---
name: Task 0059 — Dev-only `Jido.Dashboard.Endpoint` + `mix jido.dashboard` task + `guides/dashboard.md` + `guides/dashboard.livemd`
description: Ship a tiny dev-only Phoenix endpoint and Mix task that boots the dashboard standalone (`mix jido.dashboard --port 4000`), so library contributors can poke the dashboard without standing up a host Phoenix app or the showcase. Write the user-facing dashboard guide (`guides/dashboard.md`) covering mount instructions, redaction, opt-in toggle, multi-node note, and Claude Preview workflow. Write a runnable livebook (`guides/dashboard.livemd`) demonstrating end-to-end with a counter agent. Wire both into mix.exs ExDoc. Flips ADR 0026 → Accepted/Partial → leaves task 0060 as the final flip to Complete.
---

# Task 0059 — Dev runner, dashboard guide, livebook

- Implements: [ADR 0026](../adr/0026-redux-devtools-dashboard.md) §3 (mount story — dev runner half).
- Depends on: [task 0054](0054-dashboard-deps-and-scaffold.md), [task 0055](0055-dashboard-buffer-ets-and-ringbuffer.md), [task 0056](0056-dashboard-recorder-middleware.md), [task 0057](0057-dashboard-presenter-safe-terms.md), [task 0058](0058-dashboard-router-and-liveviews.md).
- Blocks: nothing in the library (task 0060 is the showcase, runs in `examples/`).
- Leaves tree: **green**.

## Context

After task 0058 the dashboard mounts cleanly into any host Phoenix
app. The library still lacks a self-contained way to **boot just the
dashboard** for development — useful when iterating on the LiveViews
without dragging the showcase Phoenix app along, or when a
contributor wants a 30-second smoke test.

The dev runner is a small `Jido.Dashboard.Endpoint` gated on
`Mix.env() == :dev` plus a `Mix.Tasks.Jido.Dashboard` that boots
it. Production builds (`MIX_ENV=prod`) compile out the endpoint
entirely.

This task also ships the user-facing docs:

- **`guides/dashboard.md`** — the operational reference. How to
  mount, how to toggle, how to redact, how to interpret the
  timeline, how to run on multiple nodes, how to preview locally
  via Claude Preview.
- **`guides/dashboard.livemd`** — a runnable demo. Open in
  Livebook, evaluate the cells, see the dashboard capture a
  counter agent's signals end-to-end. Mirrors the
  `guides/llm-agent.livemd` style.

Together they make the dashboard discoverable. After this task,
ADR 0026 flips to `Status: Accepted; Implementation: Partial` —
the final `Complete` flip lives in task 0060 once the showcase app
exists.

## Files to modify

### `mix.exs`

Add the new task and guide to ExDoc:

```elixir
extras: [
  # …
  {"guides/dashboard.md", title: "Agent Dashboard"},
  {"guides/dashboard.livemd", title: "Dashboard — Quick Start"},
  # …
]
```

Place under the `Operations` group in `groups_for_extras` (alongside
`debugging.md`, `observability.md`).

### `guides/adr/0026-redux-devtools-dashboard.md`

Flip:

```diff
- - Status: Proposed
+ - Status: Accepted
- - Implementation: Pending
+ - Implementation: Partial
```

Note in the `Related commits` line that the proof's library half is
now landed; task 0060's showcase is the final implementation step.

### `guides/adr/README.md`

Update the row for ADR 0026.

### `guides/tasks/README.md`

If task 0042's pattern of `Status` / `Impl` columns persists in the
README's task index (it does — see existing task table), add rows
for tasks 0053–0058 with status `Complete` after each lands. This
task updates the index for 0058 and earlier.

## Files to create

### `lib/jido/dashboard/endpoint.ex`

A minimal `Phoenix.Endpoint` gated on `Mix.env() == :dev`:

```elixir
if Mix.env() == :dev do
  defmodule Jido.Dashboard.Endpoint do
    use Phoenix.Endpoint, otp_app: :jido

    @session_options [
      store: :cookie,
      key: "_jido_dashboard_key",
      signing_salt: "jido-dashboard"
    ]

    socket "/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [session: @session_options]]

    plug Plug.Static, at: "/", from: {:jido, "priv/static"}
    plug Plug.Session, @session_options
    plug Plug.RequestId
    plug Plug.Logger
    plug Jido.Dashboard.DevRouter
  end
end
```

Plus a tiny `Jido.Dashboard.DevRouter` that imports the public
router macro:

```elixir
if Mix.env() == :dev do
  defmodule Jido.Dashboard.DevRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Jido.Dashboard.Router

    pipeline :browser do
      plug :accepts, ["html"]
      plug :fetch_session
      plug :fetch_live_flash
      plug :put_root_layout, html: {Jido.Dashboard.Layouts, :root}
      plug :protect_from_forgery
    end

    scope "/" do
      pipe_through :browser
      jido_dashboard "/jido-dashboard"
    end
  end
end
```

Bind to `127.0.0.1` only by default; expose `--host 0.0.0.0` flag in
the Mix task for users who want to hit it from another machine on
their LAN.

### `lib/mix/tasks/jido.dashboard.ex`

```elixir
if Mix.env() == :dev do
  defmodule Mix.Tasks.Jido.Dashboard do
    @moduledoc """
    Boots `Jido.Dashboard.Endpoint` for local exploration.

    ## Examples

        mix jido.dashboard
        mix jido.dashboard --port 4001
        mix jido.dashboard --host 0.0.0.0 --port 4000
    """
    use Mix.Task

    @impl Mix.Task
    def run(args) do
      {opts, _} = OptionParser.parse!(args, strict: [port: :integer, host: :string])
      port = Keyword.get(opts, :port, 4000)
      host = Keyword.get(opts, :host, "127.0.0.1")

      Application.put_env(:jido, Jido.Dashboard.Endpoint,
        url: [host: host, port: port],
        http: [ip: parse_ip(host), port: port],
        server: true,
        secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64()
      )

      Mix.Task.run("app.start")
      Process.sleep(:infinity)
    end

    defp parse_ip("127.0.0.1"), do: {127, 0, 0, 1}
    defp parse_ip("0.0.0.0"),   do: {0, 0, 0, 0}
    defp parse_ip(other),       do: raise "unsupported --host: #{inspect(other)}"
  end
end
```

### `guides/dashboard.md`

Sections:

1. **What it is.** One-paragraph intro: Redux-DevTools-style read-
   only timeline of every cmd; `signal`, `slice_after`, `directives`
   per row.
2. **Mounting it.** The `import Jido.Dashboard.Router; jido_dashboard
   "/path"` macro. Show a complete `MyAppWeb.Router` snippet.
   Auth pipeline note.
3. **Enabling capture per instance.** `Jido.Dashboard.enable/1` in
   IEx for ad-hoc, `config :jido, {:dashboard, MyApp.Jido}, :enabled`
   in `runtime.exs` for staging defaults. Hot path overhead when
   off (< 1 µs/signal).
4. **Redaction.** Reuses
   [`Jido.Observe`](../lib/jido/observe.ex)'s `:redact_sensitive`
   flag. Add a path to the redact list, those keys collapse to
   `[REDACTED]` in dashboard rows.
5. **Multi-node.** ETS is local; `enable/1` is per-node.
   `:rpc.multicall(Node.list(:visible) ++ [Node.self()],
   Jido.Dashboard, :enable, [instance])` for cluster-wide capture.
6. **Memory and truncation.** Default 500 rows × 64 KB cap per
   agent. Configurable via Application env. The `:truncated`
   marker in row fields.
7. **The dev runner.** `mix jido.dashboard` for a standalone boot.
8. **Claude Preview workflow.** Copy the launch.json snippet from
   the showcase, point at `mix jido.dashboard --port 4000` if
   running library-only. (The showcase has its own.)
9. **Limitations.** Single-node v1, no time-travel re-execution,
   no diff, no state edit. Pointer to ADR 0026 / 0027 for context.

Length target: ~400 lines including code blocks.

### `guides/dashboard.livemd`

Mirror the `guides/llm-agent.livemd` shape:

1. **Setup cell** — `Mix.install([{:jido, …}, …])`, plus
   `Phoenix` / `LiveView` / `Kino`.
2. **Define a tiny counter agent** — one slice, one
   `:increment` action.
3. **Boot the agent under a `Jido` instance.**
4. **Enable the dashboard** — `Jido.Dashboard.enable(MyApp.Jido)`.
5. **Send a few signals** — three `:increment` casts.
6. **Read the captured rows** —
   `Jido.Dashboard.Buffer.list(agent_id, limit: 10)`.
7. **Inspect the rows in Kino** — render via
   `Kino.DataTable.new(rows)` so the user sees the columns.
8. **Optional: launch the LiveView in Livebook** via
   `Kino.Frame` with the dashboard mounted in a tiny embedded
   endpoint. (Drop this step if it's brittle — the static row
   inspection above is sufficient proof.)

Length target: ~300 lines, runnable on any machine that can
`mix install :jido`.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --min-priority higher` clean.
- `mix dialyzer` clean.
- `mix test` green (no new tests in this task — endpoint and Mix
  task are dev-only and integration-tested via the showcase in
  task 0060, plus a small smoke run below).
- `mix test --include e2e` green.
- `mix docs` runs clean. Both new guides render under
  `Operations`. The dev-runner endpoint module is dev-only and
  shouldn't appear in docs.
- **Manual smoke**: in the worktree, run
  `mix jido.dashboard --port 4001`. Browser to
  `http://localhost:4001/jido-dashboard`. AgentList page renders
  with the empty-state. Open `iex -S mix`, build a tiny agent,
  enable the dashboard, send a signal. The browser tab updates
  within ~1 s.
- **Production build excludes dev runner.**
  `MIX_ENV=prod mix compile --warnings-as-errors` does not load
  `Jido.Dashboard.Endpoint` or the Mix task; verify with
  `MIX_ENV=prod mix loadpaths && elixir -e 'Code.ensure_loaded?(Jido.Dashboard.Endpoint) |> IO.inspect'`
  → `false`.
- ADR 0026 flips to `Accepted` / `Partial` in this commit. Index
  row updates accordingly.

## Out of scope

- Authn/Z hardening on the dev runner. It binds to `127.0.0.1` by
  default and that's the security boundary. `--host 0.0.0.0` is
  documented as developer-discretion.
- A `mix phx.server`-style auto-reload story for the LiveView
  templates. The library's templates are `.heex` files compiled
  with the rest of the lib; reloading is the host app's concern.
- Asset rebuild step. The dev runner serves the same hand-written
  CSS the production library ships.
- The example showcase app. Task 0060.
- Full ADR 0026 status flip to `Implementation: Complete`. That
  waits for task 0060's showcase to land.

## Risks

- **Dev-only modules leaking into prod.** `if Mix.env() == :dev do`
  guards the endpoint module definition itself, so the module
  literally doesn't exist in prod. Verify the
  `Code.ensure_loaded?/1` smoke above; do not rely on
  `Application.compile_env/3` (which evaluates the `if` at compile
  time correctly but is easier to misuse).
- **Mix task vs script.** A long-running Mix task with
  `Process.sleep(:infinity)` is the canonical pattern (mirrors
  `mix phx.server`). Don't try `mix run --no-halt`; the endpoint
  needs the application supervision tree to stay up.
- **Default `secret_key_base`.** The dev runner generates a random
  key on each boot via `:crypto.strong_rand_bytes/1`. Sessions are
  invalid across restarts, which is fine for a dev tool. Document
  this in the guide so a confused user doesn't expect login state
  to persist.
- **Livebook compatibility.** `guides/dashboard.livemd` must
  run-clean against the Livebook version the project's CI uses
  (per `guides/llm-agent.livemd`'s precedent). Test the livebook
  end-to-end on the latest Livebook before flipping the ADR.
- **Documentation drift.** The dashboard guide repeats facts from
  ADR 0026 / 0027. Keep ADRs as the canonical decision record;
  link to them from the guide rather than restating. Skim diffs
  in future PRs that touch either ADR to keep the guide aligned.
