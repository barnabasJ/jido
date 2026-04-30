---
name: Task 0060 — `examples/jido_showcase/` Phoenix app exercising Jido's feature surface end-to-end with the dashboard mounted
description: New `examples/jido_showcase/` — a full Phoenix LiveView app that demonstrates Jido in real use. Six pages: Home (tour), Chat (agentic chat against a local LM Studio model using `Jido.AI.ReAct`, mirrors `guides/llm-agent.livemd`), Pod orchestration (parent + two children), Multi-slice agent (counter + identity + memory composed via `slices: [...]`), Sensor demo (heartbeat → signal stream), and Dashboard (mounted via `jido_dashboard "/dashboard"`). Standalone `mix.exs` with path-deps on `jido` and `req_llm`, real esbuild + tailwind asset pipeline (the example *can*, the library can't). `examples/jido_showcase/.claude/launch.json` configures Claude Preview to launch `mix phx.server` on port 4000. One e2e test (`@tag :e2e`) boots the chat agent, sends a turn against LM Studio, and asserts the dashboard captured the signals. Top-level `examples/jido_showcase/README.md` with prereqs, run instructions, and a one-liner pointer in the repo root README. Flips ADR 0026 to `Implementation: Complete`.
---

# Task 0060 — Example showcase app

- Implements: [ADR 0026](../adr/0026-redux-devtools-dashboard.md) §6; flips ADR 0026 to `Implementation: Complete`.
- Depends on: [task 0054](0054-dashboard-deps-and-scaffold.md), [task 0055](0055-dashboard-buffer-ets-and-ringbuffer.md), [task 0056](0056-dashboard-recorder-middleware.md), [task 0057](0057-dashboard-presenter-safe-terms.md), [task 0058](0058-dashboard-router-and-liveviews.md), [task 0059](0059-dashboard-dev-runner-preview-and-docs.md).
- Blocks: nothing.
- Leaves tree: **green**.

## Context

The library half of the dashboard ships in tasks 0053–0058. This
task ships the **runnable proof** — a Phoenix LiveView application
under `examples/jido_showcase/` that exercises Jido's wider surface
in concrete UI flows, mounts the dashboard, and serves as the
primary manual-e2e venue going forward.

A few reasons to ship this as a sibling app under `examples/`
rather than embedded in the library:

- **Asset pipeline.** The example uses esbuild + tailwind for a
  decent UI; per [ADR 0026](../adr/0026-redux-devtools-dashboard.md),
  the library ships hand-written CSS and no JS bundle. Keeping
  build complexity in the example app keeps the library install
  surface small.
- **Heavyweight deps.** The chat page needs `req_llm` configured for
  a local LM Studio endpoint; we don't want every jido user to pull
  that as a runtime dep.
- **Standalone runnable.** `cd examples/jido_showcase && mix
  phx.server` — same shape as Phoenix's own `phoenix_examples`
  directory. Easy to clone-and-run.
- **Claude Preview home.** A `.claude/launch.json` lives at the
  example app's root; whenever a Claude Code session opens that
  directory the embedded preview browser auto-launches `mix
  phx.server`. The library doesn't need its own launch config
  once this exists (task 0059's `mix jido.dashboard` is a
  fallback).

The user's phrasing was "showcase all the agent features including
agentic chat using LM Studio and gemma 4 like we do in the livebook".
This task delivers exactly that — six pages each demonstrating a
different Jido surface, with the dashboard at the centre showing
what the agents actually did.

## Files to modify

### `mix.exs`

Add `examples/jido_showcase/lib` to `elixirc_paths` only when running
inside the example app's own Mix project, not the library's. The
library's mix.exs ignores `examples/`. No changes here unless tests
need to find example modules — they shouldn't.

### `README.md` (repo root)

Add a one-paragraph pointer near the top:

```markdown
## Looking for a runnable demo?

See [`examples/jido_showcase`](examples/jido_showcase) — a Phoenix
LiveView app that demonstrates agentic chat (against a local LM
Studio model), pod orchestration, multi-slice agents, sensors, and
the [agent dashboard](guides/dashboard.md) mounted at `/dashboard`.
```

### `guides/dashboard.md` (from task 0059)

Add a "See also" line pointing at the showcase's chat page as a
"see it live" demo.

### `guides/adr/0026-redux-devtools-dashboard.md`

Flip:

```diff
- - Implementation: Partial
+ - Implementation: Complete
```

### `guides/adr/README.md`

Update the row for ADR 0026.

## Files to create — example app structure

Standard Phoenix LiveView 1.7+ app shape. Treat this as `mix phx.new
jido_showcase --live --no-ecto` followed by hand-edits, not as a
verbatim copy of any specific template.

### `examples/jido_showcase/mix.exs`

```elixir
defmodule JidoShowcase.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_showcase,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {JidoShowcase.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

  defp deps do
    [
      # Path-dep on the parent jido library
      {:jido, path: "../.."},

      # Phoenix
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:bandit, "~> 1.5"},

      # LLM
      {:req_llm, "~> 1.9"},

      # Assets
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},

      # Test
      {:floki, ">= 0.30.0", only: :test}
    ]
  end

  defp aliases do
    [
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind default", "esbuild default"],
      "assets.deploy": ["tailwind default --minify", "esbuild default --minify", "phx.digest"]
    ]
  end
end
```

### `examples/jido_showcase/config/{config,dev,runtime,test}.exs`

Standard Phoenix configuration. `config/runtime.exs` reads the
LM Studio base URL from env (`LMSTUDIO_URL`, default
`http://localhost:1234/v1`) and the chat model from env
(`SHOWCASE_CHAT_MODEL`, default `lmstudio:gemma-2-4b-it`) — both
overridable via the chat UI at runtime. `config/dev.exs` enables
the dashboard for the showcase's `Jido` instance by default
(`config :jido, {:dashboard, JidoShowcase.Jido}, :enabled`).

### `examples/jido_showcase/.claude/launch.json`

```json
{
  "version": "0.0.1",
  "configurations": [
    {
      "name": "jido-showcase",
      "runtimeExecutable": "mix",
      "runtimeArgs": ["phx.server"],
      "port": 4000
    }
  ]
}
```

### `examples/jido_showcase/lib/jido_showcase/application.ex`

Supervision tree: PubSub, Endpoint, plus a `JidoShowcase.Jido`
instance module (`use Jido`). The dashboard middleware ships in the
default plugins per task 0056, so no additional wiring needed for
capture.

### `examples/jido_showcase/lib/jido_showcase/agents/chat.ex`

The chat agent — `use Jido.Agent` with the `Jido.AI.ReAct` slice
attached, mirroring `guides/llm-agent.livemd`'s structure. Tools:
`current_time/0`, a sample lookup tool. Configurable model via
agent ctx.

### `examples/jido_showcase/lib/jido_showcase/agents/counter.ex`

Multi-slice agent: counter slice + identity slice + memory slice
composed via `slices: [...]`. Three actions:
`:increment`, `:decrement`, `:reset`.

### `examples/jido_showcase/lib/jido_showcase/agents/heartbeat_agent.ex`

Subscribes to a heartbeat sensor; one action that runs on every
tick and updates a "last seen" timestamp.

### `examples/jido_showcase/lib/jido_showcase/pod/showcase_pod.ex`

A small pod topology: parent + two child agents. Demonstrates
`SpawnAgent` directive, lifecycle signals, and pod mutation.

### `examples/jido_showcase/lib/jido_showcase_web/router.ex`

```elixir
defmodule JidoShowcaseWeb.Router do
  use JidoShowcaseWeb, :router
  import Jido.Dashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JidoShowcaseWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", JidoShowcaseWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/chat", ChatLive, :index
    live "/pod", PodLive, :index
    live "/slices", SlicesLive, :index
    live "/sensor", SensorLive, :index
  end

  scope "/" do
    pipe_through :browser
    jido_dashboard "/dashboard"
  end
end
```

### `examples/jido_showcase/lib/jido_showcase_web/live/{home,chat,pod,slices,sensor}_live.ex`

Five LiveViews, each demonstrating one Jido surface. Shared layout
with a left nav linking to all six pages (the five demos plus the
dashboard). Each page has a "What does this demonstrate?" panel
with a 2-3 sentence explanation and links to the relevant guide.

### `examples/jido_showcase/assets/{css,js,vendor}/...`

Standard Phoenix asset layout: tailwind config, a small
`app.css` / `app.js`, the LiveView client.

### `examples/jido_showcase/test/jido_showcase/dashboard_e2e_test.exs`

```elixir
defmodule JidoShowcase.DashboardE2ETest do
  use JidoShowcaseWeb.ConnCase, async: false

  @moduletag :e2e

  test "chat turn captures signals into the dashboard" do
    # Boot a chat agent under JidoShowcase.Jido
    # Send a chat turn (or stub the LLM via Mimic for hermeticity)
    # Assert Jido.Dashboard.Buffer.list(agent_id) returns rows
    # for `chat_turn`, the ReAct slice's signals, etc.
    # Assert the dashboard LiveView at /dashboard renders with
    # those rows.
  end
end
```

The user's "tagged-not-probed" convention applies: this test is
`@tag :e2e`, excluded from default `mix test`, included via
`mix test --include e2e`. Local LM Studio reachable at the
configured URL is the expectation; if the model is not loaded the
test fails with a clear message rather than skipping silently.

### `examples/jido_showcase/README.md`

Sections:

1. **What this is.** One paragraph.
2. **Prerequisites.** LM Studio running locally, model loaded,
   Elixir 1.18+, Node 20+.
3. **Run it.**
   ```sh
   cd examples/jido_showcase
   mix deps.get
   mix assets.setup
   mix assets.build
   mix phx.server
   ```
4. **What each page demonstrates.** One paragraph per page.
5. **Configuring the chat model.** Env vars + UI override.
6. **Running the e2e test.** `mix test --include e2e` from the
   showcase directory.
7. **Screenshots.** Embed 2-3 PNGs from
   `examples/jido_showcase/priv/static/img/screenshots/`.

### `examples/jido_showcase/priv/static/img/screenshots/...`

A handful of screenshots — Home, Chat (mid-conversation),
Dashboard (signal timeline). Hand-captured during this task's
manual e2e run; commit the PNGs.

## Acceptance

- The library tree's `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --min-priority higher`,
  `mix dialyzer`, `mix test`, `mix test --include e2e` all pass —
  the showcase app is path-included in the library only via
  `:jido` path-dep semantics, not via `elixirc_paths`.
- From `examples/jido_showcase/`:
  - `mix deps.get` clean.
  - `mix assets.setup && mix assets.build` clean.
  - `mix compile --warnings-as-errors` clean.
  - `mix format --check-formatted` clean.
  - `mix phx.server` boots; browser to `http://localhost:4000`
    shows the Home page; nav to each of the six pages renders
    without errors; nav to `/dashboard` shows the AgentList page.
- Manual chat smoke: send a chat message; the response renders;
  `/dashboard` AgentList shows the chat agent; click in →
  AgentDetail shows the ReAct signal sequence with state-after
  and directives per row.
- `mix test` (from `examples/jido_showcase/`) green for the
  non-e2e tests.
- `mix test --include e2e` from the showcase directory passes
  with LM Studio running locally with the configured model.
- Claude Preview integration: opening this directory in a Claude
  Code session auto-launches the server per `.claude/launch.json`;
  `mcp__Claude_Preview__preview_navigate` to
  `http://localhost:4000/dashboard` shows the dashboard;
  `preview_screenshot` captures it cleanly.
- ADR 0026 flips to `Implementation: Complete`. The README index
  row updates accordingly. The repo root `README.md` carries the
  one-paragraph pointer to `examples/jido_showcase`.

## Out of scope

- Persisting chat history across browser refreshes. The chat
  LiveView's state is in-memory per session for v1.
- Authn/Z on showcase routes. Localhost-only, dev-only.
- Deployment instructions (Heroku / Fly / etc.). The app is a
  development demo; deployment lives outside the proof's scope.
- Additional showcase pages beyond the six listed (e.g. workflow
  orchestration, scheduling, ash integration). Future task if the
  user wants more demos.
- A separate test suite for the showcase pages' UI behaviour. v1
  ships one e2e test and relies on the library's own tests for
  Jido behaviour. Per-page LiveView unit tests are nice-to-have,
  not the proof.
- Publishing the showcase as a Hex package. It's example code,
  not a library.

## Risks

- **LM Studio dependency for the chat page.** If LM Studio isn't
  running, the chat page errors out. The page should detect this
  on mount (`Req.get/2` against the `/v1/models` endpoint) and
  show a clear "LM Studio not reachable at $URL" message with the
  configured URL and a hint. Don't crash the LiveView mount.
- **Asset build at first clone.** `mix assets.setup` downloads
  esbuild + tailwind binaries; this can fail behind corporate
  proxies. Document a `--proxy` flag note in the README.
- **Path-dep `:jido` reproducibility.** A user cloning a tagged
  Jido release and running the showcase from `examples/`
  effectively gets the library at the tag's tree state. That's
  the right behaviour; document it so no one expects the showcase
  to track Hex.
- **CI coupling.** The showcase's `mix test` shouldn't run in the
  library's CI by default — that would couple library CI to LM
  Studio availability and Phoenix asset builds. Keep them separate;
  the showcase tests run in a dedicated CI job (or only locally
  for v1).
- **Out-of-tree changes invalidating the showcase.** ADR 0025's
  reorg renames extension modules; if those renames land while
  the showcase is being written, the showcase's import paths
  rebase too. Coordinate the order: tasks 0053-0058 land first
  (they don't rename anything); 0059 lands on the post-0042 +
  post-0052 tree state.
- **Default-on dashboard in `config/dev.exs`.** Showcase users
  expect to see the dashboard work without flipping a toggle, so
  config flips it on at boot. Document in the showcase README so
  no one's surprised that the dashboard's hot path runs in their
  local server.
