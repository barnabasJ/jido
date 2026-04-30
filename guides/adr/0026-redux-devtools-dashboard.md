# 0026. Redux-DevTools-style LiveView dashboard for agent introspection

- Status: Proposed
- Implementation: Pending
- Date: 2026-04-30
- Related ADRs: [0014](0014-slice-middleware-plugin.md) (slice / middleware / plugin split), [0019](0019-actions-mutate-state-directives-do-side-effects.md) (actions mutate, directives are side effects), [0023](0023-spark-dsl-and-registerable-extensions.md) (Spark DSL surfaces).
- Related commits: — (proposed; implementation tasks [0054–0060](../tasks/README.md))

## Context

Today the Jido runtime emits `:telemetry` events at every cmd, signal,
and directive boundary; trace context (`trace_id`, `span_id`,
`parent_span_id`, `causation_id`) propagates through
[`Jido.Tracing.Context`](../../lib/jido/tracing/context.ex). What's
missing is a **first-party UI for inspecting agent state over time**.
A developer who wants to see "what signals did this agent process,
what state did it land in after each one, and what directives did the
cmd return" has to read logs, attach handlers ad-hoc, or stand up
`Phoenix.LiveDashboard` with custom pages. None of those let you
scrub through history.

The reference open-source dashboard for this is
[`agentjido/jido_studio`](https://github.com/agentjido/jido_studio) — a
standalone LiveView app that mounts via a router macro à la Oban Web,
Apache 2.0, actively developed. It's a strong shape reference but it
captures via a passive `:telemetry.attach_many/4` handler against the
existing `[:jido, :agent, :cmd, :*]` events. Those events are
deliberately payload-light (per
[`Jido.Observe`](../../lib/jido/observe.ex)'s "metadata is for IDs and
counts, not state"), so jido_studio's per-event row carries trace IDs
and durations but **no `state_after` snapshot**. State delta viewing
exists only on a separate code path (`JidoStudio.Agents.Runner`'s sync
dispatch flow), and a Redux-DevTools-style scrub through "the agent's
state at signal N" isn't possible from its event stream.

We want the missing surface in-tree: a dashboard whose unit of
observation is "this signal came in, the cmd ran, here's the resulting
state slice and the directives it returned," presented as a live
timeline that a developer can click through. The Jido side already
has the right architecture for this — `Jido.Agent.cmd/2` is pure, the
slice keyed by `slice_path` is a direct map read, and the middleware
chain (post-[ADR 0014](0014-slice-middleware-plugin.md)) gives a
deterministic seam to capture the post-cmd slice value.

## Decision

We will introduce **`Jido.Dashboard.*`** as a new in-tree extension
surface, served by Phoenix LiveView, with the v1 scope strictly bounded
to read-only signal-stream inspection.

### 1. v1 surface

A LiveView dashboard with two pages:

- **AgentList** — running agents discovered via the existing
  `Jido.AgentServer` registry / [`Jido.Discovery`](../../lib/jido/discovery.ex).
- **AgentDetail** — for one agent, a live signal timeline (most-recent
  first), and a detail panel for the selected signal showing
  `(signal, slice_path, slice_after, directives, ts, duration_ns,
  trace_id, span_id, ok?, error?)`. The timeline is a LiveView
  stream (`phx-update="stream"`); new rows arrive via
  `Phoenix.PubSub` from the capture path.

That's the entire v1. Nothing to do with re-execution, replay,
diffing, state editing, or synthetic signal dispatch. Time-travel in
v1 means **read-only state-at-signal-N**: you select a row, you see
the recorded snapshot — no agent process is touched.

### 2. In-tree namespace, not a separate package

`Jido.Dashboard.*` lives at `lib/jido/dashboard/` for the proof. The
Phoenix family deps (`:phoenix`, `:phoenix_html`, `:phoenix_live_view`)
are added directly to [`mix.exs`](../../mix.exs) — no umbrella, no
sibling app. Extracting to `jido_dashboard` as its own package is
deferred until the proof is stable; the macro surface
(`Jido.Dashboard.Router.jido_dashboard/1`) is API-preserving so the
extraction is a mechanical move when we want it.

### 3. Mount story

Host apps mount the dashboard via a router macro, the same shape
`oban_web` uses:

```elixir
import Jido.Dashboard.Router

scope "/", MyAppWeb do
  pipe_through :browser
  jido_dashboard "/jido"
end
```

The macro emits a `live_session` with the dashboard's two LiveViews.
The library ships its own static CSS at `priv/static/jido_dashboard.css`,
served via `Plug.Static` — no esbuild/tailwind in the library. Asset
build complexity stays in user apps and in
[`examples/jido_showcase/`](../../examples/jido_showcase/) (task
[0060](../tasks/0060-example-showcase-app.md)).

The library also ships a dev-only `Jido.Dashboard.Endpoint` and a
`mix jido.dashboard` task (task
[0059](../tasks/0059-dashboard-dev-runner-preview-and-docs.md)) so
contributors can boot the dashboard without a host Phoenix app.

### 4. Capture mechanism is a middleware (not telemetry-attach)

ADR [0027](0027-dashboard-capture-and-storage.md) records the
mechanism call in detail. Summary: a `Jido.Dashboard.Middleware.Recorder`
sits at the tail of the per-agent middleware chain, captures
`slice_after` directly from `agent.state[slice_path]` plus the cmd's
returned directives, and emits a domain event
(`[:jido, :dashboard, :signal, :recorded]`). A `Jido.Dashboard.Buffer`
GenServer attaches to that event, owns an ETS ring buffer, and
broadcasts each insertion over `Phoenix.PubSub`.

The middleware is **always installed** in `Jido.Agent.DefaultPlugins`;
the hot path is gated on an `Application.get_env/3` lookup so the
overhead when disabled is one ETS read against `:ac_tab` (~100–200 ns).
Toggle is per-instance: `Jido.Dashboard.enable(MyApp.Jido)` flips
capture on at runtime with no agent restart and no global GC pause.

### 5. Single-node v1; no persistence beyond ETS

ETS is local; PubSub broadcasts cross nodes but per-agent rows do not
replicate. Multi-node fan-out is a v2 concern. No Ecto adapter, no
file backing — a future `Persistence.Adapter` behaviour (the
jido_studio shape) is on the roadmap but not the proof.

### 6. Companion: the `examples/jido_showcase/` app

Task [0060](../tasks/0060-example-showcase-app.md) ships a full
Phoenix app under `examples/jido_showcase/` exercising Jido's wider
surface — agentic chat against a local LM Studio model (mirrors
`guides/llm-agent.livemd`), pod orchestration, multi-slice agent,
sensor demo — and mounts the dashboard at `/dashboard`. It is the
primary manual-e2e venue and the home for the Claude Preview
launch config. The library does not need to ship every demo
self-contained once the showcase exists.

## Consequences

- **Three new direct deps in mix.exs.** `:phoenix ~> 1.7`,
  `:phoenix_html ~> 4.0`, `:phoenix_live_view ~> 1.0`. Users without
  the dashboard pull these as transitive Hex deps but never load the
  modules unless they mount the router macro. Acceptable cost for a
  library that already ships `:phoenix_pubsub`. If this footprint
  bites later, the extraction-to-sibling-package path is open.
- **The dashboard becomes the third visible "what does my agent do"
  surface in tree.** Logs (via `Jido.Telemetry`), structured tracing
  (via `Jido.Observe`), and now this LiveView. Each has a different
  cost / fidelity tradeoff: logs are always-on and lossless;
  telemetry is always-on and ID-only; the dashboard is opt-in per
  instance and carries `slice_after`.
- **Hot-path overhead when off.** Every `use Jido.Agent` agent runs
  the dashboard middleware; the disabled-path budget is < 1 µs per
  signal (one Application env read). Benchmark in task
  [0056](../tasks/0056-dashboard-recorder-middleware.md).
- **Memory ceiling per agent.** ETS ring is 500 rows by default with
  a 64 KB external-term-size cap per row → ~32 MB worst-case per
  agent. Configurable. LLM agents with large `slice_after` hit
  truncation often; the row carries a `:truncated` marker.
- **Single-node only.** Documented in
  [`guides/dashboard.md`](../dashboard.md). `enable/1` on one node
  does not enable others; `:rpc.multicall` is the v1 escape hatch
  for cluster-wide capture.
- **No authn/Z on the route.** The macro emits routes; mounting
  inside an auth pipeline (`pipe_through :browser_admin`) is the host
  app's call. Dev runner endpoint binds to `localhost` only.

## Alternatives considered

- **Embed `agentjido/jido_studio` as a Hex dep.** Apache 2.0,
  actively developed, already mountable. Rejected because the
  capture mechanism — telemetry-attach against payload-light events —
  cannot deliver Redux-DevTools-style "state at signal N" without a
  redesign of the event surface. Coupling our roadmap to upstream
  release cadence slows the work; building fresh keeps the design
  centred on the timeline-with-state-after primitive.
- **Ship as a sibling umbrella app from day one.** Cleaner long-term
  separation, but every mix task and contributor onboarding step
  doubles. Rejected for a proof. The extraction path remains open
  and is mechanical (`Jido.Dashboard.Router` is the only public
  surface).
- **Extend `phoenix_live_dashboard` via additional pages.** Smallest
  install footprint for users already running LiveDashboard.
  Rejected because the chrome and rendering primitives are tuned for
  metric panels, not for a per-row scrub-and-detail interaction.
  The match between Redux-DevTools and Phoenix LiveDashboard is
  poor; we'd fight the framework.
- **Drop the LiveView surface; expose only a query API
  (`Jido.Dashboard.events/2`) and let users build their own UI.**
  Useful for power users but doesn't deliver the proof the user
  asked for. The query API ships anyway as part of the
  [Buffer](../tasks/0055-dashboard-buffer-ets-and-ringbuffer.md);
  the LiveView is layered on top.
