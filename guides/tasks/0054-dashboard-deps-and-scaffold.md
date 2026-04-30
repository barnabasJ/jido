---
name: Task 0054 — Add Phoenix family deps and scaffold the `Jido.Dashboard.*` namespace
description: Add `:phoenix`, `:phoenix_html`, and `:phoenix_live_view` to mix.exs as direct deps. Create the empty module skeleton under `lib/jido/dashboard/` (`Jido.Dashboard`, `Jido.Dashboard.Buffer`, `Jido.Dashboard.Middleware.Recorder`, `Jido.Dashboard.Presenter`, `Jido.Dashboard.Router`, `Jido.Dashboard.Live.AgentList`, `Jido.Dashboard.Live.AgentDetail`). Wire `Jido.Dashboard.Buffer` into `Jido.Application` as a no-op child. Goal: a green commit that compiles cleanly with `mix compile --warnings-as-errors` so subsequent task PRs can fill in behaviour.
---

# Task 0054 — Dashboard deps and scaffold

- Implements: [ADR 0026](../adr/0026-redux-devtools-dashboard.md) §2 §3.
- Depends on: nothing in the dashboard chain (this is the entry point). Rebases on main as of [task 0053](0053-slices-as-agent-dsl-entity.md); the dashboard chain is independent of the [ADR 0025](../adr/0025-extension-directory-layout.md) extension-layout reorg and of the slices-as-DSL refactor.
- Blocks: [task 0055](0055-dashboard-buffer-ets-and-ringbuffer.md), [task 0056](0056-dashboard-recorder-middleware.md), [task 0057](0057-dashboard-presenter-safe-terms.md), [task 0058](0058-dashboard-router-and-liveviews.md).
- Leaves tree: **green**.

## Context

[ADR 0026](../adr/0026-redux-devtools-dashboard.md) decides the
dashboard ships in-tree under `lib/jido/dashboard/` with Phoenix
family deps added directly to the library. This task is the
foundation: deps land, modules exist, the supervision tree boots.
Everything else layers on top.

The scaffold deliberately ships no behaviour — every module is a
documented stub. That keeps this commit small enough to review on
its own and stops the next task (the Buffer) from blocking on the
same dep / scaffold churn.

## Files to modify

### `mix.exs`

1. Add three new deps to `defp deps/0`:

   ```elixir
   {:phoenix, "~> 1.7"},
   {:phoenix_html, "~> 4.0"},
   {:phoenix_live_view, "~> 1.0"},
   ```

   Place them next to `:phoenix_pubsub`, alphabetised. Run
   `mix deps.get` and commit the resulting `mix.lock` diff.

2. Add a new entry to `groups_for_modules` for the dashboard:

   ```elixir
   Dashboard: [
     Jido.Dashboard,
     Jido.Dashboard.Buffer,
     Jido.Dashboard.Middleware.Recorder,
     Jido.Dashboard.Presenter,
     Jido.Dashboard.Router,
     Jido.Dashboard.Live.AgentList,
     Jido.Dashboard.Live.AgentDetail
   ],
   ```

   Insert it after the `Observability` group. Module ordering follows
   the same "facade → storage → middleware → utility → router → views"
   layout used elsewhere.

### `lib/jido/application.ex`

Add `Jido.Dashboard.Buffer` to the supervision tree's `children` list.
Place it after the existing `Phoenix.PubSub` child (so the Buffer can
broadcast on it later). For this task the Buffer's `start_link/1`
just calls `Supervisor.start_link/2` with no children — it has no
state yet — but registering it in the tree now means task 0055 only
adds behaviour, not boot wiring.

## Files to create

### `lib/jido/dashboard.ex`

Public facade module. Stub module-doc + `@moduledoc` only:

```elixir
defmodule Jido.Dashboard do
  @moduledoc """
  Redux-DevTools-style LiveView dashboard for inspecting Jido agents.

  …(brief overview, link to ADR 0026 / 0027, link to guides/dashboard.md)…
  """
end
```

No functions in this commit. `enable/1`, `disable/1`, `enabled?/1`
land in [task 0056](0056-dashboard-recorder-middleware.md).

### `lib/jido/dashboard/buffer.ex`

```elixir
defmodule Jido.Dashboard.Buffer do
  @moduledoc """
  ETS-backed ring buffer of recorded dashboard signal rows.
  …
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
```

Stub the public API as `@doc false` + `raise "not implemented"`
clauses for now, or omit entirely — task 0055 adds the real shape.
Whichever keeps `mix compile --warnings-as-errors` clean with no
`@spec`-vs-`@callback` mismatches.

### `lib/jido/dashboard/middleware/recorder.ex`

Stub the middleware behaviour. The real `Jido.Middleware`
implementation lands in [task 0056](0056-dashboard-recorder-middleware.md):

```elixir
defmodule Jido.Dashboard.Middleware.Recorder do
  @moduledoc """
  Tail-of-chain middleware that captures `slice_after` and directives
  per cmd, gated on `Application.get_env(:jido, {:dashboard, instance})`.

  …(behaviour skeleton; full impl in task 0056)…
  """
end
```

### `lib/jido/dashboard/presenter.ex`

Stub. Full impl in [task 0057](0057-dashboard-presenter-safe-terms.md).

### `lib/jido/dashboard/router.ex`

Stub. Full impl in [task 0058](0058-dashboard-router-and-liveviews.md).

### `lib/jido/dashboard/live/agent_list.ex`, `lib/jido/dashboard/live/agent_detail.ex`

Stubs. Full impl in [task 0058](0058-dashboard-router-and-liveviews.md).
The two LiveView modules each compile to a no-op
`use Phoenix.LiveView` with a `@moduledoc false` — enough that the
router macro in task 0058 has real modules to point at.

### `priv/static/jido_dashboard.css`

An empty file with a 1-line header comment. Asset content lands in
task 0058. Created here so the path exists and `Plug.Static` config
in task 0058 doesn't 404 on its first compile.

## Acceptance

- `mix deps.get` succeeds; `mix.lock` is committed.
- `mix compile --warnings-as-errors` clean. (No unused-variable, no
  undefined-function, no missing-`@moduledoc` warnings on the new
  modules — every stub gets a real moduledoc.)
- `mix format --check-formatted` clean.
- `mix credo --min-priority higher` clean.
- `mix dialyzer` clean. (Stub modules with no functions emit no
  contracts; this should be trivial.)
- `mix test` clean. (Existing suite unaffected.)
- `mix test --include e2e` clean.
- `iex -S mix` boots without crash; `Jido.Dashboard.Buffer` appears
  in `:observer.start()` under `Jido.Application`.
- `mix docs` runs clean. The new `Dashboard` group renders in the
  module index; each stub module shows its moduledoc.

## Out of scope

- Any actual capture, storage, presentation, or rendering behaviour.
  Each lands in its own task: 0054 (Buffer), 0055 (Recorder
  middleware), 0056 (Presenter), 0057 (Router + LiveViews).
- Adding `Jido.Dashboard.Middleware.Recorder` to
  `Jido.Agent.DefaultPlugins`. That's task 0056 — until the
  middleware does real work, installing it in every agent's chain
  has no effect but also no value.
- Asset pipeline (esbuild / tailwind). Per ADR 0026 the library
  ships hand-written CSS; the empty `priv/static/jido_dashboard.css`
  here is the placeholder.
- Dev-only `Jido.Dashboard.Endpoint` and the `mix jido.dashboard`
  task. Those land in task 0059.
- Any guide or livebook content. Task 0059.
- Any work in `examples/jido_showcase/`. Task 0060.

## Risks

- **Phoenix version mismatch with downstream apps.** `phoenix ~> 1.7`
  / `phoenix_live_view ~> 1.0` are the floor for current Phoenix.
  Apps on 1.6 will have to upgrade to consume jido `>= 2.3`.
  Document in `guides/dashboard.md` (task 0059); call out in the
  CHANGELOG when this lands.
- **`mix.lock` churn.** Three new top-level deps pull a small fan of
  transitives (`plug`, `plug_crypto`, `mime`, `telemetry`, …; most
  already in the lock as transitives). Review the lockfile diff
  before committing; reject any unintended bumps.
- **`Jido.Application` start order.** Place the Buffer **after**
  `Phoenix.PubSub` (which it'll later broadcast on) but before any
  user-facing supervisors. If the existing tree has supervisor-order
  invariants (cron scheduler, registry), maintain them.
