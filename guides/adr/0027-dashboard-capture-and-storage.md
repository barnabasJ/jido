# 0027. Dashboard capture is a middleware emitting a domain event; storage is ETS; toggle is Application env

- Status: Proposed
- Implementation: Pending
- Date: 2026-04-30
- Related ADRs: [0014](0014-slice-middleware-plugin.md) (middleware as a single-tier extension surface), [0019](0019-actions-mutate-state-directives-do-side-effects.md) (slice_after is the canonical post-cmd state read), [0026](0026-redux-devtools-dashboard.md) (the dashboard this capture mechanism feeds).
- Related commits: — (proposed; implementation tasks [0055](../tasks/0055-dashboard-buffer-ets-and-ringbuffer.md), [0056](../tasks/0056-dashboard-recorder-middleware.md))

## Context

[ADR 0026](0026-redux-devtools-dashboard.md) decides we ship a
LiveView dashboard whose unit of observation is "this signal arrived,
the cmd produced this slice state and these directives." It does not
say *how* we capture that record — capture mechanism, sequence
generation, storage, redaction, and the runtime enable/disable flag
are separable enough to record on their own.

Three of these have plausible alternatives that picked the wrong way
would either leak metadata into a global event, pause the BEAM
under runtime toggle, or fail to capture `slice_after` deterministically.
This ADR pins them.

### What's in tree today

- `:telemetry.execute([:jido, :agent, :cmd, :start | :stop | :exception], …)`
  fires from inside `Jido.Agent.cmd/2` via
  [`Jido.Observe.with_span/3`](../../lib/jido/observe.ex). Per the
  module's own moduledoc, metadata is **for IDs and counts, not state
  payloads** — adding `slice_after` here pollutes a global event that
  Prometheus / OpenTelemetry handlers attach to.
- The middleware chain is single-tier (post
  [ADR 0014](0014-slice-middleware-plugin.md)): a 2-arity function
  `(Signal.t, ctx -> {ctx, [directive]})` composed by
  [`Jido.AgentServer`](../../lib/jido/agent_server.ex) at boot. Slice
  state lives at `agent.state[slice_path]`; the cmd's return shape
  ([ADR 0018](0018-tagged-tuple-return-shape.md)) makes
  `slice_before` / `slice_after` cheap to compute around the cmd
  call.
- [`Jido.Debug`](../../lib/jido/debug.ex) is the closest
  runtime-toggle precedent — per-instance verbosity flag stored in
  `:persistent_term`. Reads are ~30 ns, but
  `:persistent_term.put/2` triggers a full-node GC scan to find
  references to the old term and can pause every process on the box
  for milliseconds.
- [`Jido.Observe.Config`](../../lib/jido/observe/config.ex) reads
  per-instance config via `Application.get_env(:jido, instance, [])`
  — that's the existing convention for per-instance keyed config in
  this codebase.

### What `agentjido/jido_studio` does (the divergence point)

The reference dashboard project takes the telemetry-attach path.
[`JidoStudio.TraceBuffer`](https://github.com/agentjido/jido_studio/blob/main/lib/jido_studio/trace_buffer.ex)
attaches with `:telemetry.attach_many/4` to the prefix list returned
by `JidoStudio.TraceCatalog.configured_events/0` —
`[[:jido, :agent, :cmd, :_], [:jido, :agent_server, :signal, :_],
[:jido, :ai, :react, :_], …]`. No middleware, no AgentServer patch.

The cost: each captured row carries event metadata only — no
`state_after`, no slice value. Studio compensates by capturing
`state_before` / `state_after` on a separate path
([`JidoStudio.Agents.Runner`](https://github.com/agentjido/jido_studio/blob/main/lib/jido_studio/agents/runner.ex))
that calls `Jido.AgentServer.state(pid)` around synchronous
interactive dispatches from the studio's runner UI. That path covers
"user-initiated turn" but **does not capture every cmd as it happens
in production traffic**.

For a Redux-DevTools-style timeline the studio's split won't do.
Either every row carries `state_after` or the time-travel feature
isn't useful. We pay the cost — opt-in capture per instance — to
get deterministic per-cmd snapshots.

## Decision

### 1. Capture is a middleware named `Jido.Dashboard.Middleware.Recorder`

The middleware ships in `Jido.Agent.DefaultPlugins` so every
`use Jido.Agent` agent has it as the **last** entry in its middleware
chain by default. The hot path is:

```elixir
def on_signal(signal, ctx, opts, next) do
  case Application.get_env(:jido, {:dashboard, ctx.instance}) do
    :enabled ->
      {ctx_after, directives} = next.(signal, ctx)
      record_signal(signal, ctx_after, directives)
      {ctx_after, directives}

    _ ->
      next.(signal, ctx)
  end
end
```

The `record_signal/3` step is only reached when capture is enabled.
It builds the row, truncates, redacts, and emits the domain event
`[:jido, :dashboard, :signal, :recorded]` via
`Jido.Observe.emit_event/3`. The middleware itself does **not** write
ETS or PubSub directly — that's the `Buffer`'s job (see §3).

Sitting at the tail of the chain matters: any middleware that
mutates `slice_after` between Recorder and the cmd would make the
dashboard's record stale. We document the contract; we do not add a
Spark verifier in v1.

### 2. The captured row

Each row is a map with these keys:

| Key | Type | Source |
|---|---|---|
| `seq` | non-neg integer | `:ets.update_counter/3` on a per-agent counter row in the storage table |
| `ts_ns` | integer (monotonic ns) | `System.monotonic_time(:nanosecond)` |
| `agent_id` | binary | `ctx.agent_id` |
| `signal` | `%Jido.Signal{}` (presented) | the inbound signal |
| `slice_path` | atom | `ctx.slice_path` |
| `slice_after` | term (presented + truncated) | `agent.state[slice_path]` after the cmd |
| `directives` | list (presented) | the cmd's returned directives |
| `duration_ns` | integer | `ts_after - ts_before` |
| `trace_id` / `span_id` | binary | `Jido.Tracing.Context.current/0` |
| `ok?` | boolean | true if cmd returned `{:ok, …}` |
| `error?` | term \| nil | error term when not ok |

`signal`, `slice_after`, and `directives` are **presented**, not raw
— pids/refs become strings, large binaries truncate, structs without
`Jason.Encoder` flatten to `inspect/2` output. The Presenter
([task 0057](../tasks/0057-dashboard-presenter-safe-terms.md)) is
called at capture time so the row that lands in ETS is already
JSON-safe and bounded.

A row whose total `:erlang.external_size/1` exceeds 64 KB (default,
configurable) collapses to a `:truncated` marker on the offending
field with the original size recorded. This bounds memory under
pathological agent state (LLM conversation history, large embeddings).

### 3. Storage is ETS; the owner is `Jido.Dashboard.Buffer`

A single named ETS table `:jido_dashboard_signals`,
`:ordered_set`, `read_concurrency: true`, `write_concurrency: true`,
keyed by `{agent_id, seq}`. Writes are direct
`:ets.insert/2` calls from inside the telemetry handler — the
GenServer does not gate writes (the table is `:public`), so writes
are lock-free across agents.

The owner GenServer attaches to `[:jido, :dashboard, :signal,
:recorded]` at app boot, owns the table, and:

1. Inserts each event into ETS.
2. Bumps a per-agent counter (`{agent_id, :counter}` row) via
   `:ets.update_counter/3`.
3. If the agent's row count exceeds `max_per_agent` (default 500),
   evicts the lowest-`seq` row via a small bounded `:ets.select_delete`.
4. Broadcasts the new row over `Phoenix.PubSub` topic
   `"jido:dashboard:agent:#{agent_id}"`.

Public query API: `Buffer.list(agent_id, opts)`,
`Buffer.get(agent_id, seq)`, `Buffer.clear(agent_id)`,
`Buffer.agents/0`. LiveViews use `list/2` for backfill on mount and
the PubSub topic for live tailing.

ETS rows survive AgentServer restarts — captured history doesn't
vanish when the agent crashes and restarts under the supervisor.

### 4. Runtime toggle is `Application.get_env`, not `:persistent_term`

The hot path gate is:

```elixir
case Application.get_env(:jido, {:dashboard, instance}) do
  :enabled -> capture(...)
  _ -> :ok
end
```

Public facade in
[`lib/jido/dashboard.ex`](../../lib/jido/dashboard.ex):

```elixir
def enable(instance),  do: Application.put_env(:jido, {:dashboard, instance}, :enabled)
def disable(instance), do: Application.delete_env(:jido, {:dashboard, instance})
def enabled?(instance), do: Application.get_env(:jido, {:dashboard, instance}) == :enabled
```

`Application.get_env/3` reads from the public `:ac_tab` ETS table —
~100–200 ns, no process round-trip. `Application.put_env/3` is a
GenServer call to `:application_controller` — a few microseconds,
**no global GC pause**. That last point is why we picked Application
env over `:persistent_term`: the dashboard is a tool you might toggle
during incident response, and the difference between "sub-microsecond
write, no side effects" and "millisecond GC pause that touches every
process on the node" matters when the box is already on fire.

The compile-time / boot-time alternative for staging environments
that want capture on by default:

```elixir
# config/runtime.exs
config :jido, {:dashboard, MyApp.Jido}, :enabled
```

The same key shape that `Jido.Observe.Config` already uses for
per-instance config.

### 5. Redaction reuses the existing surface

`Jido.Observe.redact/2` and the `:redact_sensitive` flag in
`Jido.Observe.Config` already exist for the telemetry path. The
dashboard uses the same function; sensitive paths declared at the
slice / agent level for telemetry redaction redact in the dashboard
too. No new redaction API.

## Consequences

- **The global telemetry event surface stays payload-light.**
  `[:jido, :agent, :cmd, :*]` continues to carry IDs and counts
  only, which is what Prometheus / OpenTelemetry / structured-log
  consumers want. Dashboard payloads ride on the dashboard's own
  domain event so consumers can opt in or out cleanly.
- **Always-on overhead has a hard ceiling.** When the dashboard is
  off (the `:prod` default), every `use Jido.Agent` agent pays one
  Application env read per signal. Task
  [0056](../tasks/0056-dashboard-recorder-middleware.md)
  microbenchmarks the disabled path to confirm the < 1 µs/signal
  budget. Users with truly tight loops can override DefaultPlugins
  to omit the middleware.
- **Per-agent row counter via `:ets.update_counter/3` is lock-free.**
  Unlike jido_studio's per-stream `GenServer.call`-serialized
  monotonic seq, our writes parallelise across agents. The owner
  GenServer is on the eviction path only.
- **Memory bounded per agent.** 500 rows × 64 KB ≈ 32 MB ceiling
  per agent. Configurable via `Application.get_env(:jido,
  :dashboard_max_per_agent)`. LLM agents that pack huge state into
  one slice will see frequent `:truncated` markers and that's fine —
  the row still tells you the signal handled and the directives
  emitted.
- **Toggle is per-instance and per-node.** No magic cluster-wide
  fan-out. Operators who want capture on every node use
  `:rpc.multicall(Node.list(:visible) ++ [Node.self()],
  Jido.Dashboard, :enable, [instance])`. Single-line, well-known
  pattern, documented in the dashboard guide.
- **Test isolation is the user's job (with help).** Tests that flip
  the toggle must `Application.delete_env/2` in `on_exit/1` or
  pollute downstream tests. The dashboard guide and task
  [0056](../tasks/0056-dashboard-recorder-middleware.md) acceptance
  call this out; standard Elixir testing pattern.
- **No `Persistence.Adapter` behaviour in v1.** Storage is ETS-only.
  We may steal jido_studio's adapter shape (`Persistence.ETS` /
  `Persistence.Ecto`) in a future ADR once the proof is stable;
  that's a v2 surface decision, not the proof.

## Alternatives considered

- **Enrich `[:jido, :agent, :cmd, :stop]` metadata with `slice_after`
  and let a telemetry handler consume it (jido_studio's path,
  upgraded).** Rejected because the metadata is consumed by metrics
  reporters too, and shipping multi-KB payloads through the global
  telemetry event harms every other consumer. The cleaner answer is
  a separate domain event on a separate channel.
- **Capture in a dedicated GenServer per agent.** Each AgentServer
  spawns or attaches a recorder process; writes go via
  `GenServer.cast/2`. Rejected: serialises writes per agent, adds
  one process per agent (the framework already runs many), and the
  ETS-table-with-counter-row design is simpler and faster. The
  GenServer we keep is the table owner (`Jido.Dashboard.Buffer`),
  not a per-agent worker.
- **Piggyback on `%Jido.AgentServer.State.debug_events`.** That ring
  buffer already exists (max 500 events) gated on `debug: true`.
  Rejected because (a) it dies with the GenServer — captured history
  vanishes on agent restart, (b) it's per-server in-memory only —
  no cross-process query path, (c) the field carries every debug
  event, not signal-keyed dashboard rows; pollution in either
  direction.
- **`:persistent_term` for the runtime toggle (the
  `Jido.Debug` shape).** Rejected for the GC-pause reason in §4.
  `Jido.Debug` keeps `:persistent_term` because it's a dev-time
  verbosity flag flipped once a session; the dashboard toggle is a
  different access pattern.
- **A custom `read_concurrency: true` ETS control table for the
  toggle.** Buys ~100 ns per read over Application env (~80 ns vs
  ~180 ns) — invisible at any realistic throughput, and adds a
  whole infrastructure surface (table owner, table name, registration,
  cleanup on `disable/1`) for a flag that already has a perfectly
  good home in Application env. Rejected as premature.
- **Pre-serialize rows to JSON at capture time** (jido_studio's
  Ecto adapter does this for storage). Rejected for the in-memory
  path — keeping the row as an Elixir term lets the LiveView decide
  how to render and lets us defer Jason encoding to socket-frame
  time. JSON serialization happens at the wire boundary, not the
  storage boundary.
