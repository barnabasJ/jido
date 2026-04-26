# 0020. Synchronous `AgentServer.call/4` takes a selector; `cast_and_await/4` retires

- Status: Accepted
- Implementation: Pending — tracked by [task 0013](../tasks/0013-call-takes-selector-cast-and-await-retires.md).
- Date: 2026-04-26
- Supersedes: [ADR 0016 §1 `cast_and_await/4`](0016-agent-server-ack-and-subscribe.md) (the per-signal ack primitive) and the `AgentServer.call/3` state-returning shape from [ADR 0002](0002-signal-based-request-reply.md). [ADR 0016 §2 `subscribe/4`](0016-agent-server-ack-and-subscribe.md) is unchanged.
- Related ADRs: [0002](0002-signal-based-request-reply.md), [0006](0006-external-sync-uses-signals.md), [0016](0016-agent-server-ack-and-subscribe.md), [0018](0018-tagged-tuple-return-shape.md)

## Context

Today `Jido.AgentServer` exposes three primitives for cross-process interaction with an agent:

| | Synchronous? | Carries an answer? | Server-decides what crosses the boundary? |
|---|---|---|---|
| `cast/2` | no | no | n/a |
| `call/3` | yes | yes — `{:ok, %Agent{}}` | **no** — full agent struct leaks |
| `cast_and_await/4` | partly (caller blocks) | yes — selector return | yes |
| `subscribe/4` | no (ambient) | yes — selector return | yes |

Two of these claim "synchronous request → answer" semantics with different shapes:

- `call/3` returns the full agent struct. The caller has unrestricted access to whatever the agent module's state happens to be. This is exactly the [ADR 0002](0002-signal-based-request-reply.md) anti-pattern — the boundary leaks server internals — and the [ADR 0016](0016-agent-server-ack-and-subscribe.md) Context section explicitly flagged it. We didn't fix it then.
- `cast_and_await/4` ([agent_server.ex:411-446](../../lib/jido/agent_server.ex)) layers an ack-table protocol on top of `GenServer.cast`: the caller registers an ack entry via a synchronous `GenServer.call({:register_ack, ...})`, casts the signal, then receives a `{:jido_ack, ref, payload}` message dispatched after the chain unwinds. This requires ~80 lines of state plumbing — `pending_acks` map, monitor tracking on both sides, `:cancel_ack` and `:DOWN` handlers, `drop_dead_pending_ack/2`, etc. — most of which exists to handle edge cases (caller dies during wait, timeout cleanup, retry middleware multi-invocation) that `GenServer.call` already handles natively.

The cast+ack design pre-dated the selector pattern's introduction in [ADR 0016](0016-agent-server-ack-and-subscribe.md). At the time, it shared infrastructure with `subscribe/4`'s ambient pattern (signal_subscribers map). With selectors now established as the boundary-shaping mechanism, `cast_and_await` becomes redundant: a `GenServer.call` whose handler runs the chain and then evaluates the caller's selector against post-pipeline state delivers the same semantics in a fraction of the code.

The original ADR 0016 alternative ("registration synchronous with the cast so there's no subscribe-too-late race") doesn't apply to per-signal acks — `GenServer.call` arrives in the mailbox, then handle_call processes it (running the chain inline), then the selector runs. There's no race window. The race concern was inherited from `subscribe/4`'s ambient design, where it does apply.

## Decision

### 1. The principle

**If you call, you take a selector.** Synchronous interaction with an agent always carries a caller-provided projection function that decides what crosses the boundary. There is no "give me the state" primitive; the caller asks a *specific question* and the server answers exactly that.

Three primitives, with consistent selector semantics:

| | Synchronous? | Selector? | Returns |
|---|---|---|---|
| `cast/2` | no | no | `:ok` (fire and forget) |
| `call/4` | yes | required | `{:ok, value}` / `{:error, reason}` from the selector |
| `subscribe/4` | no (ambient) | required | per-event dispatch via the selector |

Each primitive's selector signature is identical: `(State.t() -> {:ok, term()} | {:error, term()} | :skip)`. `call/4` doesn't accept `:skip` (the caller is blocking; "skip" has no meaning), but the shape parallels `subscribe/4` so the same selector can be reused.

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

### 5. `AgentServer.state/1` stays

`AgentServer.state/1` ([agent_server.ex:363-368](../../lib/jido/agent_server.ex)) returns the full `%AgentServer.State{}` and is kept per [ADR 0006](0006-external-sync-uses-signals.md) for liveness checks and bootstrap. It does *not* trigger signal processing. It's not a substitute for `call/4` — it's a debug/observability primitive whose use should be limited to bootstrap, tests, and operator inspection.

If `state/1` becomes a load-bearing channel for normal traffic, that's a smell pointing at a missing typed query API. Don't dilute the rule by reaching for `state/1`.

### 6. `subscribe/4` is unchanged

Ambient subscription with pattern + selector keeps its current shape from ADR 0016 §2. The ack-table-style `signal_subscribers` map stays — different semantics from `call/4`, justified by "fires repeatedly across signals" which `GenServer.call` can't model.

## Consequences

- **`AgentServer` API simplifies.** Three primitives instead of four. Each has a clear role: cast for fire-and-forget, call for synchronous request, subscribe for ambient observation.

- **~80 lines of cast_and_await/ack-table code disappear.** `pending_acks` field, register_ack handler, cancel_ack handler, drop_dead_pending_ack helper, fire_ack_for_signal post-hook, and the receive-loop dance in `cast_and_await/4` itself.

- **Pipeline-running code extracted into `process_signal/2`.** Both `handle_cast({:signal, ...})` and `handle_call({:signal_with_selector, ...})` go through the same helper. Single source of truth for chain execution + state commit.

- **`Pod.Mutable.mutate/3` rewritten** to call `AgentServer.call/4` with the existing default selector. The signature stays `{:ok, %{mutation_id: id, queued: true}} | {:error, term()}`; only the underlying primitive changes.

- **`Pod.Mutable.mutate_and_wait/3` rewritten** likewise — it already uses `cast_and_await/4` for the queued-ack step, then receives lifecycle subscription messages. After this ADR, the queued-ack step uses `call/4`; the subscription step is unchanged. (Task 0010's separate redesign of `mutate_and_wait/3` to subscribe to natural child lifecycle signals layers on top.)

- **Consistent selector ergonomics.** A user who learns the selector shape from `subscribe/4` can reuse it with `call/4` — same `(state -> {:ok, _} | {:error, _})` contract. Reduces the surface to learn.

- **GenServer.call timeout edge case.** If a caller times out, the GenServer might still process the message and try to reply to a gone process. The reply lands on a dead pid and is discarded. This is OTP folklore-level untidy, not actually a problem. The cast+ack design's "explicit cancel_ack" was a slightly cleaner cleanup but bought little in practice.

- **No more "registration synchronous with the cast" claim in ADR 0016.** That framing applied to `subscribe/4` (where it remains valid — subscribers must register before signals start arriving) but was incidentally extended to `cast_and_await/4` where it doesn't actually buy anything. With this ADR, the framing is correctly scoped.

- **Migration cost is bounded.** `cast_and_await/4` has two in-tree callers (`Pod.Mutable.mutate/3` and `Pod.Mutable.mutate_and_wait/3`). `AgentServer.call/3` (state-returning) has a handful of test callsites and `Pod.Actions.QueryNodes`-style internal call paths to audit. Out-of-tree callers break per NO-LEGACY-ADAPTERS — we don't owe them a smooth runtime upgrade.

## Alternatives considered

**Keep both `call/3` and `cast_and_await/4`, just delete the state-returning shape.** Half-fix: replace `call/3`'s `{:ok, %State{}}` return with a selector, leaving `cast_and_await/4` alone. Rejected: the two primitives would do the same job (synchronous request + selector projection). Two ways to express one operation. The "shared infrastructure with subscribe" argument for `cast_and_await/4` is real but small, and `subscribe/4` already exists independently — keeping `cast_and_await/4` *just* for that symmetry is paying complexity without a use case.

**Rename `cast_and_await/4` to `call/4` and delete the old `call/3`.** Smallest diff: keep the cast+ack implementation, just call it `call/4`. Rejected: the cast+ack mechanism (pending_acks, register_ack, cancel_ack, monitors) is the bloat we want to remove. Renaming preserves the ceremony. Going through `GenServer.call` directly is the simplification.

**Keep `AgentServer.call/3` as a debug helper.** Rename it to `dump_state/1` or expose under a clearly-namespaced debug API. Rejected: anyone holding a reference to "the easy way to get state" will use it. Make the easy thing the right thing — `call/4` with a selector. Operators who need full state for debugging use `AgentServer.state/1`, which is documented as a debug/bootstrap primitive.

**Make selectors optional on `call/4`.** Default to a selector that returns `{:ok, agent}` if none given. Rejected: defeats the principle. The whole point is that synchronous boundary-crossing is a deliberate choice about what to expose. Make every caller name that choice.

**Add a `call_async/4` primitive that does cast+receive without server-side blocking, for cases where the caller wants to do other work between sending and receiving.** Rejected for now: no in-tree caller wants this. Spawn a task and call `call/4` from there if needed. Adding the primitive prematurely commits to its semantics.

**Defer the change until a concrete use case forces it.** Smallest behavior change: keep `cast_and_await/4` and `call/3` as-is, just document the asymmetry. Rejected: every new feature that wants synchronous request semantics has to choose between two near-identical primitives, and the wrong choice (state-leaking `call/3`) is the easy default. Codify the rule before more code accumulates around the wrong shape.
