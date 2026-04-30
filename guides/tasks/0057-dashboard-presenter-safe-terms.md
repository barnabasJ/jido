---
name: Task 0057 — `Jido.Dashboard.Presenter` (safe term presentation for the LiveView wire)
description: Walk an arbitrary Elixir term and produce a Jason-safe, bounded representation. Pids, refs, ports, funs become strings (`"#PID<0.123.0>"` etc.). Binaries over a configurable byte cap truncate to a head + `...` marker. Maps and lists deeper than a depth cap collapse to `:truncated_depth`. Atoms, integers, floats, booleans, nil pass through. Structs without `Jason.Encoder` flatten to `inspect/2` output. Output is a deterministic Jason-safe term — no opaque data shapes reach LiveView assigns or PubSub broadcasts. Pure functions; property-based tests via `stream_data` (already a dep).
---

# Task 0057 — Presenter: safe terms for the wire

- Implements: [ADR 0027](../adr/0027-dashboard-capture-and-storage.md) §2 (the "presented" treatment of `signal`, `slice_after`, `directives`).
- Depends on: [task 0054](0054-dashboard-deps-and-scaffold.md).
- Blocks: [task 0056](0056-dashboard-recorder-middleware.md) (the Recorder calls the Presenter), [task 0058](0058-dashboard-router-and-liveviews.md).
- Leaves tree: **green**.

## Context

`Jido.Agent.state` carries arbitrary Elixir terms — pids and refs in
some agents, large binaries in LLM agents, function values, structs
without `Jason.Encoder`. Pushing that through the LiveView wire (or
a `Phoenix.PubSub.broadcast/3` payload, or even into ETS — though
ETS doesn't care about Jason) makes `phoenix_live_view` raise on
encode and tanks the user experience.

The Presenter is the canonical "make this safe to render" surface:

- Always Jason-safe output. After the Presenter has run, `Jason.encode!/1`
  on the result must succeed.
- Bounded size. A configurable byte cap on binaries plus a depth cap
  on maps/lists prevents megabyte payloads from reaching socket
  assigns. The Recorder additionally enforces a row-level
  `:erlang.external_size/1` cap; the Presenter's binary cap is the
  per-field complement.
- Lossy but informative. We don't need the original; we need a
  human-readable, debuggable representation. `"#PID<0.123.0>"` is
  more useful in a UI than panicking on a non-encodable term.

This is a small, focused, pure-functional module. Property-based
tests via `stream_data` (already in `mix.exs` test deps) prove
"every Elixir term goes in, valid JSON comes out" without needing
a hand-curated fixture corpus.

## Files to modify

### `lib/jido/dashboard/presenter.ex`

Replace the task 0054 stub with the real module.

Public API:

```elixir
@type opts :: [
  binary_byte_cap: pos_integer(),
  depth_cap: pos_integer()
]

@spec present(term(), opts()) :: term()
```

Defaults: `binary_byte_cap: 4_096`, `depth_cap: 16`. Both
configurable per call and via `Application.get_env(:jido,
:dashboard_presenter, [...])` for global override.

Internal walk function:

- `nil`, `boolean`, `integer`, `float`, `atom`: pass through.
- `binary`: if `byte_size(b) <= binary_byte_cap`, pass through; else
  return `%{__truncated__: :binary, head: <<b::binary-size(64)>>,
  size: byte_size(b)}`. The `head` length is fixed (~64 bytes) so
  the operator can recognise common prefixes (URLs, JSON tokens).
- `pid`, `reference`, `port`, `function`: `inspect/1`-stringified.
- `tuple`: convert to `%{__tuple__: [list of presented elements]}`.
  Tuples aren't JSON-native and Jason would reject them anyway.
- `list`: walk; truncate to `depth_cap` items and append
  `%{__truncated__: :list, total: original_length}` if longer.
- `map`: walk keys and values; if depth > `depth_cap`, collapse to
  `%{__truncated__: :depth, depth: current}`. Keys that aren't
  binary/atom get stringified (`inspect/1`).
- `struct`: if `Jason.Encoder` is implemented for the struct,
  delegate to its impl by way of converting via `Map.from_struct/1`
  and walking the result with a `__struct__: ModuleName` key
  preserved. Otherwise, fall back to `%{__inspect__:
  inspect(term)}`.

Add a `@doc` to each public function with examples. Type spec on
the public function. No process state; no GenServer.

## Files to create

### `test/jido/dashboard/presenter_test.exs`

Cover via a mix of unit tests and property tests:

**Unit tests** — one per term shape:

- `nil`, booleans, integers, floats, ascii atoms pass through.
- A 4 KB binary passes through; a 4 KB + 1-byte binary truncates
  with the `__truncated__: :binary` shape and `size:` set to the
  original length.
- A pid stringifies to a string starting with `"#PID<"`.
- A ref / port / fun stringify to their respective `#Reference<…>`
  / `#Port<…>` / `#Function<…>` forms.
- A tuple `{:ok, "value"}` becomes `%{__tuple__: [":ok", "value"]}`
  (atoms encoded by their `Atom.to_string/1` form for keys; for
  list items the atom passes through unless it's not Jason-safe —
  in that case stringify).
- A map deeper than `depth_cap: 2` collapses past depth 2 with
  `%{__truncated__: :depth, depth: 3}`.
- A list longer than `depth_cap: 5` keeps the first 5, appends
  `%{__truncated__: :list, total: actual_length}`.
- A struct without `Jason.Encoder` impl flattens to
  `%{__inspect__: inspect(...)}`.
- A struct *with* `Jason.Encoder` impl (e.g. `%Jido.Signal{}`)
  walks normally and `Jason.encode!/1` round-trips.

**Property tests** (via `stream_data`):

- For any term in `term()` (a generator that mixes integers,
  binaries, atoms, lists, maps, tuples, pids, refs at random),
  `Presenter.present(term) |> Jason.encode!()` always succeeds.
- For any term, `Presenter.present(term)` is idempotent —
  `Presenter.present(Presenter.present(term)) ==
  Presenter.present(term)`.
- For any term, the result has bounded size:
  `:erlang.external_size(Presenter.present(term, depth_cap: 4,
  binary_byte_cap: 256)) <= some_constant_K`. Pin K via the test;
  it asserts the cap mechanism works regardless of input.

Run the property tests with `max_runs: 200` (the default 100 is
enough for shallow shapes; bump for confidence on deeper random
maps).

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --min-priority higher` clean.
- `mix dialyzer` clean.
- `mix test test/jido/dashboard/presenter_test.exs` green
  (both unit and property suites).
- `mix test --include e2e` green.
- `mix docs` includes the Presenter module under the `Dashboard`
  group with rendered `@doc` examples.

## Out of scope

- Pretty-printing for human readers (multi-line indent, syntax
  highlighting). The Presenter's job is to produce a JSON-safe
  Elixir term; the LiveView template handles formatting.
- Reverse path (re-hydrating a presented term back to the
  original). Lossy by design; "I had a pid here" is what the
  inspector shows.
- Custom protocols for user-defined struct presentation. If a user
  wants a special render, they implement `Jason.Encoder` for their
  struct (standard Elixir hook).
- Streaming / chunked output for very large terms. Single-pass walk
  with a depth cap is sufficient for the dashboard's row-by-row
  rendering.

## Risks

- **`Jason.Encoder` protocol detection.** `Code.ensure_loaded?/1`
  + `Jason.Encoder.impl_for/1` is the canonical pattern; use it,
  don't roll your own. Watch out for lazy module loading at
  test-suite startup.
- **Struct round-trip with `__struct__:` key.** When the Presenter
  preserves struct metadata via `__struct__: ModuleName`, the
  resulting map is valid JSON but the struct identity is gone.
  The LiveView needs to render `__struct__` cleanly (or skip it);
  task 0058's templates handle this.
- **Property test flakiness.** `stream_data` shrinks failures; with
  pids and refs in the generator the shrinker can be slow on
  failure. Cap shrink iterations (`max_shrinking_steps: 100`) so
  the suite stays fast.
- **Atom keys vs binary keys.** Phoenix's LiveView socket prefers
  string-keyed maps for client templates. The Presenter outputs
  atom keys where the input had atoms; the LiveView template
  layer converts at render time. Don't push atom-key normalisation
  into the Presenter — it makes the round-trip lossy in a way the
  inspector view loses information.
