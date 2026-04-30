---
name: Task 0058 — `Jido.Dashboard.Router` macro + AgentList / AgentDetail LiveViews + minimal CSS
description: Implement the mountable router macro (Oban-Web style — `import Jido.Dashboard.Router; jido_dashboard "/path"` emits routes into a host `live_session`). Implement two LiveViews: `Jido.Dashboard.Live.AgentList` lists running agents discovered via the registry / `Jido.Discovery`; `Jido.Dashboard.Live.AgentDetail` subscribes to the per-agent PubSub topic, backfills via `Jido.Dashboard.Buffer.list/2`, renders the signal timeline as a LiveView stream (`phx-update="stream"`), and shows signal detail on selection (signal + state-after + directives, formatted by the Presenter). Inline CSS in `priv/static/jido_dashboard.css`; no esbuild / tailwind in the library. Flips ADR 0026 to `Implementation: Partial`.
---

# Task 0058 — Router macro and LiveViews

- Implements: [ADR 0026](../adr/0026-redux-devtools-dashboard.md) §1 §3; flips ADR 0026 to `Implementation: Partial`.
- Depends on: [task 0054](0054-dashboard-deps-and-scaffold.md), [task 0055](0055-dashboard-buffer-ets-and-ringbuffer.md), [task 0056](0056-dashboard-recorder-middleware.md), [task 0057](0057-dashboard-presenter-safe-terms.md).
- Blocks: [task 0059](0059-dashboard-dev-runner-preview-and-docs.md), [task 0060](0060-example-showcase-app.md).
- Leaves tree: **green**.

## Context

After tasks 0053–0056 the capture pipeline is complete: agents have
the Recorder middleware, enabling the dashboard for an instance
records every cmd's signal/state-after/directives into the Buffer's
ETS ring, and each insertion broadcasts on per-agent PubSub topic.
This task adds the user-facing surface.

The mount story is the Oban-Web pattern — a router macro that emits
a `live_session` with the dashboard's LiveViews into the host app's
router. No separate Endpoint, no app of its own (those land in task
0058 as a dev convenience). The macro is the only public surface
that ships from the library; everything else is implementation.

The two LiveViews are intentionally minimal for v1:

- **AgentList** — one row per running agent. Click → AgentDetail.
- **AgentDetail** — the heart of the proof. Left column: signal
  timeline, newest at top, streamed via `phx-update="stream"` from
  the PubSub topic. Right column: detail of the selected signal —
  the signal envelope, the agent's slice state after the cmd, and
  the directives the cmd returned. All three blocks rendered from
  the Presenter's already-Jason-safe output.

Asset story: a single hand-written CSS file in `priv/static/`,
served via `Plug.Static` from the macro. No esbuild, no tailwind,
no JS bundle beyond the LiveView client that comes with the
`phoenix_live_view` dep.

## Files to modify

### `lib/jido/dashboard/router.ex`

Replace the task 0054 stub with the real macro:

```elixir
defmacro jido_dashboard(path, opts \\ []) do
  quote bind_quoted: [path: path, opts: opts] do
    scope path, alias: false, as: false do
      pipe_through(:browser)

      live_session :jido_dashboard,
        layout: {Jido.Dashboard.Layouts, :live},
        root_layout: {Jido.Dashboard.Layouts, :root} do
        live "/", Jido.Dashboard.Live.AgentList, :index
        live "/agents/:agent_id", Jido.Dashboard.Live.AgentDetail, :show
      end
    end
  end
end
```

The `pipe_through :browser` is the host app's pipeline name —
documented as a convention. If host apps name their browser
pipeline differently (`:browser_admin` etc.), they pass it via
`opts[:pipe_through]`.

Plus a `static_paths/0` function that the host app can pipe into
its `Plug.Static` config:

```elixir
def static_paths, do: ~w(jido_dashboard.css)
```

### `lib/jido/dashboard/live/agent_list.ex`

Replace stub. `mount/3`:

- Read the list of agents currently in the Buffer
  (`Jido.Dashboard.Buffer.agents/0`).
- For each, fetch a small summary (last signal timestamp, total
  count) via `Jido.Dashboard.Buffer.list/2`.
- Subscribe to `"jido:dashboard:agents"` topic for new agent
  notifications (Buffer broadcasts on this when a row is recorded
  for a previously-unseen `agent_id`).

`render/1`: a table with `agent_id`, last-signal-ts, signal count,
link to `/agents/:agent_id`.

### `lib/jido/dashboard/live/agent_detail.ex`

Replace stub. `mount/3`:

- Read `params["agent_id"]`.
- Subscribe to `"jido:dashboard:agent:#{agent_id}"` topic.
- Backfill the timeline:
  `Jido.Dashboard.Buffer.list(agent_id, limit: 100)` newest-first.
- Initialise the LiveView stream:
  `stream(socket, :signals, rows)`.
- Initial selected row: the newest one.

`handle_info({:dashboard_signal, row}, socket)`:

- `stream_insert(socket, :signals, row, at: 0, limit: 100)`.

`handle_event("select", %{"seq" => seq}, socket)`:

- Look up the row from the stream's known rows (or refetch via
  `Buffer.get/2`); update `:selected` assign.

`render/1`: two-column layout. Left: timeline with rows (signal
type, ts, ok?/error). Right: three collapsible sections —
"Signal", "State after", "Directives" — each formatted from the
Presenter's already-safe term via a small recursive Heex component.

### `lib/jido/dashboard/components.ex`

A new module for the small reusable Heex components: a tree
renderer for Presenter output (handles `__truncated__`,
`__tuple__`, `__inspect__` shapes), a row component for the
timeline, a kbd-shortcut hint footer.

### `lib/jido/dashboard/layouts.ex` and templates

A bare layout (no nav, no analytics, no telemetry beacons) that
includes the dashboard CSS and the LiveView socket. Two
templates: `root.html.heex` and `live.html.heex`.

### `priv/static/jido_dashboard.css`

Replace the task 0054 placeholder with hand-written CSS for the
two LiveViews. Target ~200 lines:

- Reset minimum (no full normalize.css).
- Two-column layout for AgentDetail, single-column for AgentList.
- Table row hover, monospace blocks for raw payloads, subtle
  truncation marker styling (italic gray).
- Print-friendly fallback (`@media print`).

No external fonts; system font stack only. No JS bundle from the
library.

### `lib/jido/application.ex`

If the macro relies on a `Jido.PubSub` instance being supervised,
ensure it's already in the children list (it is, from task 0054).
No changes expected.

### `guides/adr/0026-redux-devtools-dashboard.md`

Flip front matter:

```diff
- - Implementation: Pending
+ - Implementation: Partial
```

The remaining `Pending` → `Partial → Complete` step happens in
task 0059 (dev runner + docs) and the final flip on task 0060
(showcase) — the proof isn't done until the example exists and
the guide ships.

### `guides/adr/README.md`

Update the row for ADR 0026.

## Files to create

### `test/jido/dashboard/router_test.exs`

A small test that uses Phoenix's router introspection:

- Build a minimal `MyAppRouter` in the test that imports
  `Jido.Dashboard.Router` and calls `jido_dashboard "/dash"`.
- Assert the `MyAppRouter.__routes__/0` includes the two live
  routes at `/dash` and `/dash/agents/:agent_id`.
- Assert the `live_session` name is `:jido_dashboard`.

### `test/jido/dashboard/agent_list_live_test.exs`

Use `Phoenix.LiveViewTest`:

- Render the LiveView; assert "no agents recorded" empty state.
- Insert a synthetic row via `Jido.Dashboard.Buffer.record/1`,
  remount, assert the agent appears in the list.
- Click the row's link; assert redirect to `/agents/:agent_id`.

### `test/jido/dashboard/agent_detail_live_test.exs`

Use `Phoenix.LiveViewTest`:

- Pre-populate the Buffer with 5 synthetic rows for one agent.
- Mount the LiveView at `/agents/:agent_id`; assert all 5 rows
  appear in the timeline, newest first.
- Push a 6th row via `Buffer.record/1`; assert the LiveView
  receives the PubSub message and the row appears at the top.
- Click a row; assert the right pane updates to show that row's
  signal/state/directives.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --min-priority higher` clean.
- `mix dialyzer` clean.
- `mix test` green, including all three new test files.
- `mix test --include e2e` green.
- `mix docs` runs; the dashboard module group includes Router,
  AgentList, AgentDetail, Components, Layouts.
- `iex -S mix` smoke (manual): build a tiny router, mount the
  dashboard, point a browser at it, see the two LiveViews. (Real
  manual e2e is task 0059 / 0059.)
- ADR 0026 front matter is flipped to `Implementation: Partial`
  in this commit.

## Out of scope

- Authn/Z. The macro emits routes; the host app's pipeline does
  auth. Document this in `guides/dashboard.md` (task 0059).
- Filtering / search inside the timeline. v1 ships the raw stream;
  filtering is a v2 surface.
- Diffing between adjacent signals. v2.
- Time-travel re-execution. v2.
- esbuild / tailwind / asset bundling. The library ships hand-CSS;
  the showcase app (task 0060) is allowed to use a real pipeline.
- The dev-only `Jido.Dashboard.Endpoint` and `mix jido.dashboard`
  task — task 0059.
- A favicon. The default browser empty-favicon is fine for v1.

## Risks

- **`live_session` name collisions.** Two `jido_dashboard` macro
  invocations in the same router would emit duplicate
  `live_session :jido_dashboard` blocks and fail to compile. Use a
  generated name keyed off the path (`:"jido_dashboard_#{path |>
  Phoenix.Naming.underscore}"`) so a host app can mount the
  dashboard at multiple paths if it wants — though the use case is
  niche.
- **Stream rehydration on rejoin.** When the LiveView socket
  rejoins (browser tab inactive, network blip), the stream's
  client state is gone but the server still holds the buffered
  rows. The `mount/3` backfill via `Buffer.list/2` covers this:
  on every mount, the timeline reads the latest 100 rows from
  ETS and inserts them into the stream. PubSub messages arriving
  during the rejoin window are caught by the new subscription; a
  small race window where one message is missed is acceptable for
  v1 (the next page refresh fixes it).
- **CSS scope leakage into host apps.** Without a build step, our
  CSS class names share the global namespace. Prefix every class
  with `jido-dashboard-` to avoid collision. Document the prefix
  rule in `priv/static/jido_dashboard.css` so future contributors
  follow it.
- **`Phoenix.LiveView` major bumps.** LiveView 1.0 has a stable API,
  but the streaming primitive (`stream_insert/4` with `:limit`)
  arrived in a recent minor. Lock to the minor version that
  supports `:limit` — confirm against the dep at task 0054
  landing.
- **Agent `:_id` discovery on AgentList.** v1 enumerates
  `Buffer.agents/0` (agents with at least one captured row). An
  agent that's running but has had the dashboard disabled all
  along won't appear. This is the correct v1 behaviour ("the
  dashboard shows what was captured") but document it on the
  empty-state.
