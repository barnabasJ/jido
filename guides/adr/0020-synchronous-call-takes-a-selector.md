# 0020. Every cross-boundary read takes a selector; `cast_and_await/4` retires; uniform `(server, ..., opts)` shape

- Status: Accepted
- Implementation: Pending — tracked by [task 0013](../tasks/0013-call-takes-selector-cast-and-await-retires.md).
- Date: 2026-04-26
- Supersedes: [ADR 0016 §1 `cast_and_await/4`](0016-agent-server-ack-and-subscribe.md) (the per-signal ack primitive) and the `AgentServer.call/3` state-returning shape from [ADR 0002](0002-signal-based-request-reply.md). [ADR 0016 §2 `subscribe/4`](0016-agent-server-ack-and-subscribe.md) is unchanged.
- Related ADRs: [0002](0002-signal-based-request-reply.md), [0006](0006-external-sync-uses-signals.md), [0016](0016-agent-server-ack-and-subscribe.md), [0018](0018-tagged-tuple-return-shape.md)

## Context

Today `Jido.AgentServer` exposes a mixed surface for cross-process interaction with an agent:

| | Synchronous? | Carries an answer? | Server-decides what crosses the boundary? | Takes opts? |
|---|---|---|---|---|
| `cast/2` | no | no | n/a | no |
| `call/3` | yes | yes — `{:ok, %Agent{}}` | **no** — full agent struct leaks | timeout only |
| `cast_and_await/4` | partly (caller blocks) | yes — selector return | yes | yes |
| `subscribe/4` | no (ambient) | yes — selector return | yes | yes |
| `state/1` | yes (no signal) | yes — `{:ok, %State{}}` | **no** — full server state struct leaks | no |
| `await_ready/2` | yes (waits) | no (just `:ok`) | n/a | timeout only |
| `await_child/3` | yes (waits) | yes — `{:ok, pid}` | bounded (one pid) | yes |

Two structural problems show up across the surface:

**Inconsistent boundary discipline.** Two synchronous primitives (`call/3`, `state/1`) leak full structs across the process boundary. This is exactly the [ADR 0002](0002-signal-based-request-reply.md) anti-pattern that [ADR 0016](0016-agent-server-ack-and-subscribe.md) flagged for `call/3` — but `state/1` slipped through because it was justified by [ADR 0006](0006-external-sync-uses-signals.md)'s "liveness and bootstrap" use cases. The rule "callers shouldn't see server internals" was applied selectively. The result: any caller wanting to read state has the easy-but-leaky `state/1` to reach for, and discipline depends on convention rather than API shape.

**Inconsistent shape.** Some primitives take opts (with `:timeout` and other knobs), some take a bare timeout, some take nothing. Argument-position guesswork at every callsite. Nothing forbids a future addition that bypasses opts and takes another bare argument.

The deeper duplication is on the synchronous-with-answer side:

- `call/3` returns the full agent struct. The caller has unrestricted access to whatever the agent module's state happens to be. This is exactly the [ADR 0002](0002-signal-based-request-reply.md) anti-pattern — the boundary leaks server internals — and the [ADR 0016](0016-agent-server-ack-and-subscribe.md) Context section explicitly flagged it. We didn't fix it then.
- `cast_and_await/4` ([agent_server.ex:411-446](../../lib/jido/agent_server.ex)) layers an ack-table protocol on top of `GenServer.cast`: the caller registers an ack entry via a synchronous `GenServer.call({:register_ack, ...})`, casts the signal, then receives a `{:jido_ack, ref, payload}` message dispatched after the chain unwinds. This requires ~80 lines of state plumbing — `pending_acks` map, monitor tracking on both sides, `:cancel_ack` and `:DOWN` handlers, `drop_dead_pending_ack/2`, etc. — most of which exists to handle edge cases (caller dies during wait, timeout cleanup, retry middleware multi-invocation) that `GenServer.call` already handles natively.
- `state/1` returns the entire `%AgentServer.State{}`. Reasonable for liveness ("did the GenServer reply?"), but a sledgehammer for bootstrap or test inspection where the caller actually wants two or three fields.

The cast+ack design pre-dated the selector pattern's introduction in [ADR 0016](0016-agent-server-ack-and-subscribe.md). At the time, it shared infrastructure with `subscribe/4`'s ambient pattern (signal_subscribers map). With selectors now established as the boundary-shaping mechanism, `cast_and_await` becomes redundant: a `GenServer.call` whose handler runs the chain and then evaluates the caller's selector against post-pipeline state delivers the same semantics in a fraction of the code. The same selector mechanism applies cleanly to `state/1` — and once both primitives use selectors, the two-flavor split becomes "do I want signal pipeline behavior or pure read?" rather than "which one happens to leak less."

The original ADR 0016 alternative ("registration synchronous with the cast so there's no subscribe-too-late race") doesn't apply to per-signal acks — `GenServer.call` arrives in the mailbox, then handle_call processes it (running the chain inline), then the selector runs. There's no race window. The race concern was inherited from `subscribe/4`'s ambient design, where it does apply.

## Decision

### 1. The principle

**Anything that crosses the process boundary takes a selector.** Synchronous calls, ambient subscriptions, state reads — all carry a caller-provided projection function that decides what crosses the boundary. The agent server never hands out its full struct. The minimum data crosses; the caller asks a *specific question* and the server answers exactly that.

**Every primitive takes `opts \\ []`.** Even `cast/2` (which returns nothing across the boundary) takes opts for things like dispatch overrides, telemetry tags, future knobs. Uniform shape: `(server, ..., opts)`.

The unified surface:

| | Synchronous? | Selector? | Opts? | Returns |
|---|---|---|---|---|
| `cast/3` | no | no (no answer) | yes | `:ok` |
| `call/4` | yes (signal pipeline) | required | yes | `{:ok, value}` / `{:error, reason}` from selector |
| `subscribe/4` | no (ambient) | required | yes | dispatched per-event via selector |
| `state/3` | yes (no signal pipeline) | required | yes | `{:ok, value}` / `{:error, reason}` from selector |
| `unsubscribe/2` | yes (admin) | n/a (no data) | n/a | `:ok` |
| `await_ready/2` | yes (waits) | n/a (no data — `:ok`) | yes | `:ok` / `{:error, _}` |
| `await_child/3` | yes (waits) | n/a (returns one pid by definition) | yes | `{:ok, pid}` / `{:error, _}` |

Each selector's signature is identical: `(State.t() -> {:ok, term()} | {:error, term()} | :skip)`. `call/4` and `state/3` don't accept `:skip` (the caller is blocking; "skip" has no meaning), but the shape parallels `subscribe/4` so the same selector can be reused across primitives.

`await_ready/2` and `await_child/3` are exceptions to "selector required": the boundary data they carry is structurally minimal (success-or-not for `await_ready`; one pid for `await_child`) and the use case is "wait for a known thing to happen." A selector wouldn't add information.

### 2. `AgentServer.call/4` is the unified synchronous primitive

```elixir
@spec call(server(), Signal.t(), selector :: (State.t() -> {:ok, term()} | {:error, term()}),
           opts :: keyword()) :: {:ok, term()} | {:error, term()}
def call(server, %Signal{} = signal, selector, opts \\ [])
    when is_function(selector, 1) do
  timeout = Keyword.get(opts, :timeout, Defaults.agent_server_call_timeout_ms())
  with {:ok, pid} <- resolve_server(server) do
    GenServer.call(pid, {:signal_with_selector, signal, selector}, timeout)
  end
end
```

Server side:

```elixir
def handle_call({:signal_with_selector, signal, selector}, _from, state) do
  case process_signal(state, signal) do
    {:ok, new_state, _directives} ->
      {:reply, selector.(new_state), new_state}

    {:error, ctx, reason} ->
      # ADR 0018 §1 3-tuple error: middleware-staged ctx.agent commits;
      # selector is NOT invoked on error path.
      committed_state = %{state | agent: ctx.agent}
      {:reply, {:error, reason}, committed_state}
  end
end
```

`process_signal/2` is a refactor-extracted helper that runs the middleware chain and applies its result. Today, that work happens inline inside `handle_cast({:signal, ...})`; task 0013 extracts it so both `handle_cast` and `handle_call` can call it without duplication.

### 3. `cast_and_await/4` is deleted

Every caller migrates to `call/4`. The function, the `pending_acks` map field, the `{:register_ack, ...}` and `{:cancel_ack, ...}` handlers, the `drop_dead_pending_ack/2` helper, and the `fire_ack_for_signal/3` post-hook are all removed. Per the [tasks NO-LEGACY-ADAPTERS rule](../tasks/README.md), no shim or alias.

`fire_post_signal_hooks/3` simplifies to just `fire_subscribers/2` — the ack-firing branch is gone because acks are now handle_call replies.

### 4. The state-returning `call/3` is deleted

Anyone whose code looked like `{:ok, agent} = AgentServer.call(pid, signal)` and then poked at `agent.state` rewrites with a selector that extracts only what they need:

```elixir
# Before
{:ok, agent} = AgentServer.call(pid, signal)
counter = agent.state.counter

# After
{:ok, counter} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent.state.counter} end)
```

This is more verbose for the trivial cases. That's the point — every cross-boundary read is now an explicit decision about what to expose.

### 5. `AgentServer.state/1` becomes `state/3` with a selector

The state-leaking `state/1` retires alongside the state-leaking `call/3`. The new shape:

```elixir
@spec state(server(), call_selector(), keyword()) :: {:ok, term()} | {:error, term()}
def state(server, selector, opts \\ []) when is_function(selector, 1) do
  timeout = Keyword.get(opts, :timeout, Defaults.agent_server_call_timeout_ms())
  with {:ok, pid} <- resolve_server(server) do
    GenServer.call(pid, {:read_state_with_selector, selector}, timeout)
  end
end
```

Server side, no signal pipeline runs — it's a pure read:

```elixir
def handle_call({:read_state_with_selector, selector}, _from, state)
    when is_function(selector, 1) do
  {:reply, selector.(state), state}
end
```

Use cases that previously took the full struct rewrite trivially:

```elixir
# Liveness / "is the process alive and healthy?"
{:ok, :ok} = AgentServer.state(pid, fn _ -> {:ok, :ok} end)

# Bootstrap / "what's my agent_id?"
{:ok, id} = AgentServer.state(pid, fn s -> {:ok, s.id} end)

# Test inspection / "what's the counter slice?"
{:ok, counter} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.counter} end)
```

The contract preserved per [ADR 0006](0006-external-sync-uses-signals.md) is: liveness and bootstrap reads via a synchronous primitive that doesn't trigger signal processing. The contract narrowed by this ADR is: those reads name what they want explicitly.

If you really want the full struct (debugging, REPL inspection), the verbose form is your hint that this is a debug-only operation:

```elixir
{:ok, full_state} = AgentServer.state(pid, fn s -> {:ok, s} end)
```

### 6. `cast/2` becomes `cast/3` with opts

```elixir
@spec cast(server(), Signal.t(), keyword()) :: :ok | {:error, term()}
def cast(server, %Signal{} = signal, opts \\ []) do
  ...
end
```

No selector — fire and forget — but opts for uniform shape across the surface. Today's `cast/2` callers add `[]` (or it's defaulted) on migration.

### 7. `await_ready/2` and `await_child/3` keep their shapes

Both already take a `(server, ..., opts)` shape (`await_ready/2` takes a bare timeout that becomes an opt; `await_child/3` already takes opts). Neither carries arbitrary data across the boundary — `await_ready` returns `:ok`/`{:error, _}`, `await_child` returns one pid by definition. A selector would add ceremony without adding information. Standardize `await_ready/2`'s timeout into opts so the shape is `await_ready(server, opts \\ [])` with `:timeout` as a key.

### 8. `subscribe/4` is unchanged

Ambient subscription with pattern + selector keeps its current shape from ADR 0016 §2. The ack-table-style `signal_subscribers` map stays — different semantics from `call/4`/`state/3`, justified by "fires repeatedly across signals" which `GenServer.call` can't model.

## Consequences

- **`AgentServer` API has uniform shape.** Every primitive is `(server, ..., opts)`. Every primitive that returns data takes a selector. The mental model collapses to: name the boundary projection, hand it to a uniformly-shaped primitive.

- **No struct ever crosses the boundary by default.** `%Agent{}` and `%AgentServer.State{}` are server-side types. Callers that want fields project them explicitly. The "I'll just grab the whole thing" anti-pattern from ADR 0002 is structurally unreachable.

- **~80 lines of cast_and_await/ack-table code disappear.** `pending_acks` field, register_ack handler, cancel_ack handler, drop_dead_pending_ack helper, fire_ack_for_signal post-hook, and the receive-loop dance in `cast_and_await/4` itself.

- **Pipeline-running code extracted into `process_signal/2`.** Both `handle_cast({:signal, ...})` and `handle_call({:signal_with_selector, ...})` go through the same helper. Single source of truth for chain execution + state commit. `state/3`'s `handle_call({:read_state_with_selector, ...})` does not call `process_signal/2` — it's a pure read.

- **`Pod.Mutable.mutate/3` rewritten** to call `AgentServer.call/4` with the existing default selector. The signature stays `{:ok, %{mutation_id: id, queued: true}} | {:error, term()}`; only the underlying primitive changes.

- **`Pod.Mutable.mutate_and_wait/3` rewritten** likewise — it already uses `cast_and_await/4` for the queued-ack step, then receives lifecycle subscription messages. After this ADR, the queued-ack step uses `call/4`; the subscription step is unchanged. (Task 0010's separate redesign of `mutate_and_wait/3` to subscribe to natural child lifecycle signals layers on top.)

- **Existing `state/1` callsites fan out into selectors.** Most callers wanted one or two fields and were grabbing the whole struct because that's what the API gave them. Migration is mechanical: replace the post-`{:ok, state}` field accesses with a selector that returns those fields. Verbose for one-field reads, but the verbosity is the point — every cross-boundary read is a deliberate decision.

- **Pod-level helpers wrap state/3 with sensible defaults.** Domain code (`Pod.fetch_state/1`, `Pod.fetch_topology/1`, `Pod.nodes/1`) can keep returning their typed projections — they're internally `state/3` calls with a baked-in selector. Helpers are allowed; the underlying primitive enforces discipline.

- **Consistent selector ergonomics across primitives.** A user who learns the selector shape from `subscribe/4` reuses it with `call/4` and `state/3` — same `(state -> {:ok, _} | {:error, _})` contract. Reduces the surface to learn.

- **GenServer.call timeout edge case.** If a caller times out, the GenServer might still process the message and try to reply to a gone process. The reply lands on a dead pid and is discarded. This is OTP folklore-level untidy, not actually a problem. The cast+ack design's "explicit cancel_ack" was a slightly cleaner cleanup but bought little in practice.

- **No more "registration synchronous with the cast" claim in ADR 0016.** That framing applied to `subscribe/4` (where it remains valid — subscribers must register before signals start arriving) but was incidentally extended to `cast_and_await/4` where it doesn't actually buy anything. With this ADR, the framing is correctly scoped.

- **Migration cost is bounded but real.** `cast_and_await/4` has two in-tree callers (`Pod.Mutable.mutate/3` and `Pod.Mutable.mutate_and_wait/3`). `state/1` has more — most pod helpers, several tests, and `Jido.Agent.WorkerPool` callsites. The migration recipe is mechanical (add a selector, drop the destructure). Out-of-tree callers break per NO-LEGACY-ADAPTERS.

## Alternatives considered

**Keep both `call/3` and `cast_and_await/4`, just delete the state-returning shape.** Half-fix: replace `call/3`'s `{:ok, %State{}}` return with a selector, leaving `cast_and_await/4` alone. Rejected: the two primitives would do the same job (synchronous request + selector projection). Two ways to express one operation. The "shared infrastructure with subscribe" argument for `cast_and_await/4` is real but small, and `subscribe/4` already exists independently — keeping `cast_and_await/4` *just* for that symmetry is paying complexity without a use case.

**Rename `cast_and_await/4` to `call/4` and delete the old `call/3`.** Smallest diff: keep the cast+ack implementation, just call it `call/4`. Rejected: the cast+ack mechanism (pending_acks, register_ack, cancel_ack, monitors) is the bloat we want to remove. Renaming preserves the ceremony. Going through `GenServer.call` directly is the simplification.

**Keep `AgentServer.call/3` and `state/1` as debug helpers.** Rename them to `dump_*` or expose under a clearly-namespaced debug API. Rejected: anyone holding a reference to "the easy way to get state" will use it. Make the easy thing the right thing — `call/4` and `state/3` with selectors. Operators who genuinely need the full struct can write `fn s -> {:ok, s} end` — verbose enough to discourage casual use, available enough that genuine debugging works.

**Make selectors optional on `call/4` / `state/3`.** Default to a selector that returns the full state if none given. Rejected: defeats the principle. The whole point is that cross-boundary reads are a deliberate choice about what to expose. Make every caller name that choice.

**Keep `state/1` as the "real" state-read primitive and add `state/3` alongside.** Two ways to read state: full struct or projected. Rejected: same problem as keeping the state-leaking `call/3` — the easy default leaks, and discipline is convention rather than API shape. The whole structural argument for collapsing to one primitive is to remove the easy-but-wrong path.

**Add a `call_async/4` primitive that does cast+receive without server-side blocking, for cases where the caller wants to do other work between sending and receiving.** Rejected for now: no in-tree caller wants this. Spawn a task and call `call/4` from there if needed. Adding the primitive prematurely commits to its semantics.

**Defer the change until a concrete use case forces it.** Smallest behavior change: keep `cast_and_await/4` and `call/3` as-is, just document the asymmetry. Rejected: every new feature that wants synchronous request semantics has to choose between two near-identical primitives, and the wrong choice (state-leaking `call/3`) is the easy default. Codify the rule before more code accumulates around the wrong shape.
