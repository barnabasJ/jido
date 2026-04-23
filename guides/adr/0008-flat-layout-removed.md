# 0008. Agent flat-layout removed; `:__domain__` slice is the default

- Status: Accepted
- Implementation: Complete
- Date: 2026-04-22
- Related commits: `8942845` (foundation); `37fa544` (persist + pod test migration); `79521a8` (doc examples); `c6fa5cf` (remaining test+lib await_completion defaults); `0f0fd1a` (agent module doc examples); `e36f08d` (guide examples)
- Supersedes: Migration section of [0005](0005-agent-domain-as-a-state-slice.md)

## Context

[ADR 0005](0005-agent-domain-as-a-state-slice.md) introduced `state_key:` as an opt-in mechanism for agents to place their domain state under a named slice (conventionally `:__domain__`), matching how plugins already own slices like `:__pod__` and `:__bus_wiring__`. The ADR kept the flat top-level layout as the default for backwards compatibility and deferred the switch to "eventually — when we're ready to make the flat layout the minority case."

With zero external users, the compatibility case is gone. Running two supported shapes forever doubles the test surface and leaves ambiguity in how to read/write agent state. The 0005 endgame is safe to land in-repo now.

## Decision

We will complete the 0005 endgame:

1. `state_key:` defaults to `:__domain__` for `use Jido.Agent`. The `nil`/flat branch in `__build_initial_state__/1` is removed. Every agent seeds its schema defaults under `agent.state[state_key]` unconditionally.

2. `__build_initial_state__/1` and `set/2` **auto-wrap** flat user-state maps into the slice. A call like `new(state: %{counter: 10})` is interpreted as "my domain slice" and stored as `%{__domain__: %{counter: 10, ...}}`. Explicit slice-layout maps (with `:__domain__` or a plugin-slice key at the top level) are taken verbatim — no double-wrapping.

3. `Jido.Agent.Strategy.Direct.run_instruction/3` drops the legacy flat-state deep-merge branch. Every action now targets a slice:
   - **ScopedAction** (action declares `state_key/0` via `Jido.Agent.ScopedAction`) — the returned map is the new value of its slice (wholesale replace).
   - **Non-scoped Action** — the returned map is deep-merged into the **agent's own slice** (not top-level state), preserving partial-update ergonomics like `{:ok, %{counter: n + 1}}`.

4. `agent.state` shape is always `%{__domain__: ..., __pod__: ..., __bus_wiring__: ..., ...}` — every user-addressable value lives inside a named slice. No more top-level mixing of user domain and plugin slices.

5. Schema-backed struct fields (e.g. `%Counter{count: 0}`) stay, per 0005. They're initialized from schema defaults at `new/1` time and are not re-synced after mutations. Removing them is a separate future refactor.

6. No `mix jido.migrate.state_key` scaffold is shipped. 0005 anticipated one; with no external users it would be unused. In-repo sites are migrated directly.

## Consequences

- **Every agent has a canonical slice.** `(slice, msg) -> new_slice` is now the default shape for `cmd/2`, matching the Elm/Redux mental model. The asymmetry 0005 flagged (agents flat, plugins scoped) is gone.

- **`cmd/2` purity is structural.** User code reads `agent.state.__domain__.X` and writes through `set/2` or action returns that target the slice. Plugin state is invisible unless explicitly targeted via state-op directives — accidental cross-slice reads are no longer possible.

- **Scoped actions are the natural shape.** `use Jido.Agent.ScopedAction, state_key: :__domain__` gets just its slice as `ctx.state` and returns `{:ok, new_slice}` with wholesale-replace semantics. Non-scoped actions still work (partial-map deep-merge into the slice) for the common ergonomics.

- **Breaking change for any out-of-repo code.** Anything reading `agent.state.user_field` at top level breaks. The fix is a mechanical rewrite to `agent.state.__domain__.user_field`.

- **State-op directives are unchanged.** `%SetPath{}`, `%DeletePath{}`, `%ReplaceState{}`, `%SetState{}`, `%DeleteKeys{}` continue to operate on the full `agent.state` map (not the slice). To target the domain slice from a state-op, prefix the path with `:__domain__` — `%SetPath{path: [:__domain__, :counter], value: 5}`.

- **Plugins are unchanged.** They already owned their slices.

## Alternatives considered

- **Ship a `mix jido.migrate.state_key` scaffold.** Rejected for this repo — there are no external users to serve. If the ecosystem grows, a task can land later without blocking the in-repo cleanup.

- **Keep the flat layout as deprecated.** Rejected. Supporting two shapes indefinitely doubles the test surface and leaves the "where does state live?" question unresolved. One shape, one answer.

- **Auto-wrap only in `new/1`, not in `set/2`.** Rejected — consistency between the two entry points is valuable, and both take the same kind of attrs map.

- **Require explicit slice layout always** (no auto-wrap). Rejected — the ergonomics of `new(state: %{counter: 10})` are worth preserving, and the wrapping is unambiguous (known-slice keys pass through verbatim).

## Migration notes (for out-of-repo code)

- `use Jido.Agent` — remove any explicit `state_key: :__domain__` (it's now the default). Don't pass `state_key: nil` — the flat layout is no longer supported.
- Assertions on `agent.state.counter` → `agent.state.__domain__.counter`.
- Map-update writes like `%{agent.state | counter: 42}` → `%{agent.state | __domain__: %{agent.state.__domain__ | counter: 42}}` or `put_in(agent.state, [:__domain__, :counter], 42)`.
- Custom `checkpoint/2` / `restore/2` callbacks: check whether you're returning the raw slice vs. the full `agent.state`. The shape you serialize is the shape callers will see — no auto-wrap applies to persistence.
- State-op directive paths targeting user-domain fields: prefix with `:__domain__` — `%SetPath{path: [:counter]}` → `%SetPath{path: [:__domain__, :counter]}`.
- Plugins unchanged — they already own their slices.
