---
name: Task 0055 — Implement `Jido.Dashboard.Buffer` (ETS owner GenServer + per-agent ring eviction + query API)
description: Replace the task 0054 stub with a real Buffer. The module owns one ETS table `:jido_dashboard_signals` (`:ordered_set`, public, read/write concurrency on, key `{agent_id, seq}`), bumps a per-agent counter via `:ets.update_counter/3`, evicts the lowest-seq row when the per-agent count exceeds `max_per_agent` (default 500), broadcasts each new row over `Phoenix.PubSub` topic `"jido:dashboard:agent:#{id}"`, and exposes `record/1`, `list/2`, `get/2`, `clear/1`, `agents/0`. Tests use synthetic rows — the real telemetry handler attach lands in task 0056.
---

# Task 0055 — Buffer: ETS ring + query API

- Implements: [ADR 0027](../adr/0027-dashboard-capture-and-storage.md) §3.
- Depends on: [task 0054](0054-dashboard-deps-and-scaffold.md).
- Blocks: [task 0056](0056-dashboard-recorder-middleware.md), [task 0058](0058-dashboard-router-and-liveviews.md).
- Leaves tree: **green**.

## Context

The Buffer is the storage half of the capture pipeline. Per
[ADR 0027 §3](../adr/0027-dashboard-capture-and-storage.md), it owns a
single named ETS table, bumps per-agent monotonic sequence numbers
without serialising through a process call, evicts the oldest row
when capacity is reached, and broadcasts each new row on a per-agent
PubSub topic.

Critically, **writes do not go through `GenServer.call`**. The table
is `:public` and the GenServer only owns the table for lifecycle
purposes. `record/1` is a direct ETS insert + counter bump + PubSub
broadcast — lock-free across agents, all from the caller's process.
The eviction sweep is bounded (`:ets.select_delete` against a
match-spec) and runs inline on insert; no separate sweeper process.

This task ships the storage and query surface in isolation. Tests
hand-craft synthetic rows. The middleware that *creates* rows lands
in [task 0056](0056-dashboard-recorder-middleware.md); the LiveView
that *reads* them lands in [task 0058](0058-dashboard-router-and-liveviews.md).

## Files to modify

### `lib/jido/dashboard/buffer.ex`

Replace the task 0054 stub with the real module. Public API:

```elixir
@type row :: %{
  seq: non_neg_integer(),
  ts_ns: integer(),
  agent_id: String.t(),
  signal: map(),
  slice_path: atom(),
  slice_after: term(),
  directives: list(),
  duration_ns: integer(),
  trace_id: String.t() | nil,
  span_id: String.t() | nil,
  ok?: boolean(),
  error: term() | nil,
  truncated: list(atom())
}

@spec record(row()) :: :ok
@spec list(String.t(), keyword()) :: [row()]
@spec get(String.t(), non_neg_integer()) :: row() | nil
@spec clear(String.t()) :: :ok
@spec agents() :: [String.t()]
```

Module behaviour:

- `start_link/1`: creates the ETS table `:jido_dashboard_signals`
  (`:ordered_set`, `:public`, `read_concurrency: true`,
  `write_concurrency: true`), stores `max_per_agent` (default 500)
  and `pubsub` (default `Jido.PubSub`) in module state, registers
  on `:via` `Jido.Dashboard.Buffer`.
- `record(row)`:
  1. Compute `seq` via `:ets.update_counter(@table, {row.agent_id, :counter}, 1, {{row.agent_id, :counter}, 0})`.
  2. Insert `{{row.agent_id, seq}, %{row | seq: seq}}`.
  3. If `seq > max_per_agent`, delete the oldest row:
     `:ets.delete(@table, {row.agent_id, seq - max_per_agent})`.
  4. Broadcast on PubSub topic `"jido:dashboard:agent:#{row.agent_id}"`
     with payload `{:dashboard_signal, row_with_seq}`.
- `list(agent_id, opts)`:
  - `since:` (default `0`) — return rows with `seq > since`.
  - `limit:` (default 100) — newest-first via `:ets.select_reverse/3`.
  - `selector:` (optional) — applied as a filter post-query.
- `get(agent_id, seq)`: `:ets.lookup(@table, {agent_id, seq})` → row | nil.
- `clear(agent_id)`: `:ets.match_delete(@table, {{agent_id, :_}, :_})`
  plus delete the counter row.
- `agents()`: enumerate distinct `agent_id`s with at least one row
  (via `:ets.match/2` over `{{:_, :counter}, :_}`).

### `lib/jido/application.ex`

The Buffer was added in task 0054 as a no-op child. Update its child
spec to pass through `max_per_agent` from
`Application.get_env(:jido, :dashboard_max_per_agent, 500)` and the
PubSub name from `Application.get_env(:jido, :dashboard_pubsub, Jido.PubSub)`.

## Files to create

### `test/jido/dashboard/buffer_test.exs`

Cover:

- `start_link/1` creates the ETS table and sets the module state.
- `record/1` inserts a row and broadcasts on PubSub. Subscribe to
  the agent's topic and assert receipt.
- Sequential `record/1` calls produce strictly monotonic `seq` per
  agent (start at 1, increment by 1).
- Concurrent `record/1` calls from N tasks for the same agent
  produce distinct, dense sequence numbers (use `Task.async_stream`).
- Ring eviction: with `max_per_agent: 5`, after 8 records the
  earliest 3 are evicted; `list/2` returns the latest 5 newest-first.
- `list/2` `since:` and `limit:` opts behave as documented.
- `get/2` returns the row for a known `seq`, `nil` otherwise.
- `clear/1` removes all rows and the counter for one agent only;
  other agents' rows are untouched.
- `agents/0` returns the set of agent_ids with at least one row.
- Tests must not leak ETS rows: each test runs under a unique
  `agent_id` (UUID per test), and `on_exit/1` calls `clear/1` for
  cleanup.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --min-priority higher` clean.
- `mix dialyzer` clean.
- `mix test test/jido/dashboard/buffer_test.exs` green.
- `mix test --include e2e` green (no regression).
- Microbenchmark sanity: 10 000 sequential `record/1` calls under
  ~50 ms (~5 µs per call). Document the number in the commit
  message; not a CI gate.
- `iex -S mix`: `Jido.Dashboard.Buffer.record(synthetic_row())` then
  `Jido.Dashboard.Buffer.list("agent_id", limit: 10)` round-trips
  manually.

## Out of scope

- The `Recorder` middleware that produces rows from real cmd
  invocations — task 0056.
- Any subscription / fan-out to LiveView. The Buffer broadcasts on
  PubSub; the LiveView attaches to that topic in task 0058. Buffer
  itself doesn't know about LiveViews.
- Persistence beyond ETS. No Ecto, no file writeback. ADR 0027 §3
  records this; `Persistence.Adapter` is a v2 surface.
- Multi-node row replication. Single-node v1 per
  [ADR 0026 §5](../adr/0026-redux-devtools-dashboard.md).
- Telemetry attach. The Buffer in this task exposes `record/1` as
  the only ingestion entry point; task 0056 attaches the telemetry
  handler that calls `record/1`.

## Risks

- **Concurrent eviction races.** Two concurrent `record/1` calls
  for the same agent could both observe a count > max and both try
  to evict the same row. `:ets.delete/2` is idempotent so this is
  not a correctness bug, but a tight loop might evict more than
  necessary. Acceptable for v1; document, revisit if it shows up
  in the benchmark.
- **PubSub broadcast cost.** `Phoenix.PubSub.broadcast/3` adds
  ~10-50 µs per row when subscribers exist. For agents with no
  dashboard subscribers this is wasted — but the alternative
  (subscriber registration via `Phoenix.Tracker`) costs more in
  steady state. Accept the broadcast cost; flip the toggle off
  per [ADR 0027 §4](../adr/0027-dashboard-capture-and-storage.md)
  to skip it entirely.
- **`:ets.update_counter/3` against a missing row.** The default
  argument syntax `{{key, :counter}, 0}` initialises if absent —
  must be on a tuple shape that matches the ordered_set keying
  (the counter row uses `{agent_id, :counter}` to stay distinct
  from data rows whose key is `{agent_id, integer_seq}`). Verify
  with the concurrent-record test.
- **Test cross-talk via the global ETS table.** The test suite runs
  multiple `Buffer` tests concurrently against the **same**
  `:jido_dashboard_signals` table (it's named/global). Per-test
  `agent_id` UUIDs prevent row collision; `on_exit/1`'s `clear/1`
  prevents heap growth. Do not try to run a per-test isolated
  Buffer — the table name is fixed by ADR 0027 and that's correct
  for production; use `agent_id` namespacing in tests.
