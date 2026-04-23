# 0016. Waiting on agents: ack + subscribe on AgentServer

- Status: Proposed
- Implementation: Pending
- Date: 2026-04-23
- Related commits: —
- Supersedes: [0010](0010-waiting-via-ack-and-subscribe.md)

## Context

Three overlapping mechanisms exist today for "hear back from an agent":

- `Jido.AgentServer.await_completion/2` ([agent_server.ex:369-412](../../lib/jido/agent_server.ex)) parks a waiter on `state.completion_waiters` and wakes it when the agent's state reaches a terminal status. The caller configures *paths* but not *values* — the terminal atoms `:completed`/`:failed` are hardcoded at [agent_server.ex:2310-2321](../../lib/jido/agent_server.ex). FSM agents with richer terminal atoms (`:won`/`:lost`/`:cancelled`) can't plug in without a wrapper action.
- `Jido.Signal.Call.call/3` ([ADR 0002](0002-signal-based-request-reply.md)) — a correlation-id receive loop that casts a query signal and waits for a reply. Actions must opt in by emitting `%Directive.Reply{}`; if they forget, the caller hangs until timeout.
- `Jido.AgentServer.call/2` — a `GenServer.call` that returns `{:ok, %State{}}`. Leaks the full state struct, the exact [ADR 0002](0002-signal-based-request-reply.md) anti-pattern.

There is **no subscribe/unsubscribe primitive**. Fan-out observability requires either the emitter knowing about subscribers up-front, or an out-of-band PubSub topic. There is no way for a consumer to join an agent's output stream after the fact.

[ADR 0010](0010-waiting-via-ack-and-subscribe.md) proposed `cast_and_await/4` + `subscribe/4` primitives and pinned their hook point to "after `execute_directives/3`." Two things need revisiting under the newer [ADR 0014](0014-slice-middleware-plugin.md):

1. `execute_directives/3` now sits inside the innermost `on_signal` middleware. "After `execute_directives/3`" is ambiguous — inside the innermost layer, or after the full chain unwinds?

2. 0010's examples use `state.__domain__`. Under 0014, `:__domain__` retires and every agent declares `path:`.

The primitives themselves are right; the placement and examples need updating.

## Decision

Two primitives on `Jido.AgentServer`. Both take a caller-provided selector that runs **in the agent process** and returns the value to push back. The selector's return is the only thing that crosses the process boundary. **Both primitives are AgentServer concerns, wrapping the entire middleware chain from the outside.**

### 1. `cast_and_await/4` — per-signal ack with selector

```elixir
@spec cast_and_await(server(), Signal.t(), selector :: (map -> any),
                     opts :: keyword()) ::
        {:ok, any()} | {:error, term()}
```

- The caller registers an ack entry **before** the signal enters any middleware. Entry keyed on `signal.id`:

    ```elixir
    state.pending_acks :: %{signal_id => %{
      caller_pid, ref, monitor_ref, selector
    }}
    ```

  Registration is synchronous with the cast so there's no subscribe-too-late race — the ack is present before any middleware sees the signal.

- After the **outermost** middleware's `on_signal` returns (all middleware unwound, core pipeline executed, directives applied), `AgentServer` looks up the ack by `signal.id`, runs `selector.(agent.state)` in-process, sends `{:jido_ack, ref, {:ok, selector_return}}` to `caller_pid`, and removes the entry.

- Selectors read whatever final agent state results from the full pipeline. If middleware swallowed the signal (never called `next`), the state is unchanged; the selector still runs and sees that unchanged state. No special `:swallowed_by_middleware` contract — callers express "nothing happened" through the selector's own return shape (e.g. returning `:no_change` or a stable sentinel).

- Retry middleware re-invoking `next` three times produces one ack per input signal (the ack wraps the outermost invocation, not each `next` call).

- On unexpected error during `on_signal` or directive execution, the selector is not invoked; the caller receives `{:jido_ack, ref, {:error, reason}}`.

- Timeout on the caller side cancels the ack entry (`GenServer.cast {:cancel_ack, ref}`).

- Bounded scope: this ack is for the input signal's full pipeline run. Loop-back signals (emitted via `%Directive.Emit{dispatch: nil}`) and async-result signals are **separate** pipeline runs with their own acks available.

### 2. `subscribe/4` + `unsubscribe/2` — ambient subscribe with selector

```elixir
@spec subscribe(server(), signal_pattern :: term(),
                selector :: (map -> any), opts :: keyword()) ::
        {:ok, sub_ref :: reference()} | {:error, term()}

@spec unsubscribe(server(), sub_ref :: reference()) :: :ok
```

- Subscriber entries:

    ```elixir
    state.signal_subscribers :: %{sub_ref => %{
      pattern_compiled, selector, dispatch, monitor_ref
    }}
    ```

- `pattern` uses the same router matching the agent already uses for `signal_routes` — exact type, wildcard (`"work.*"`), or `{path, match_fn}` tuples. Subscription points are the **input** signal types the agent already declares it consumes. No new vocabulary.

- **Hook point: same as ack — after the outermost middleware unwinds, pipeline complete.** For each subscriber whose pattern matches the input signal type, run `selector.(agent.state)` in-process and dispatch the result via its dispatch config. Default dispatch: `{:pid, target: self()}`, delivered as `{:jido_subscription, sub_ref, %{signal_type: t, value: selector_return}}`.

- Pattern matching runs before selector runs; non-matching signals neither invoke the selector nor cross the boundary.

- Middleware-swallowed signals still fire subscribers whose patterns match — the subscriber observes the (unchanged) post-pipeline state, same as the ack primitive. Callers who want to distinguish "processed" from "swallowed" encode it in the selector (e.g. by checking a counter or timestamp that only advances when the signal reaches an action).

- Subscribers are monitored; `DOWN` drops the entry.

### Error handling

If the selector raises, log it (with the subscriber/ack ref for traceability) and send an error variant to the caller. A crashing selector must not kill the agent.

### Example — completion waits under the new primitives

```elixir
# Single-cast completion — wait for one signal's full pipeline
{:ok, {:completed, answer}} =
  AgentServer.cast_and_await(pid, Signal.new!("work.start", %{}),
    fn s ->
      case s.domain do
        %{status: :completed, last_answer: r} -> {:completed, r}
        %{status: :failed, error: e}          -> {:failed, e}
        _                                     -> :not_terminal
      end
    end)

# Multi-signal completion — observe any pipeline until terminal
{:ok, ref} = AgentServer.subscribe(pid, "*",
  fn s ->
    case s.domain do
      %{status: :completed, last_answer: r} -> {:completed, r}
      %{status: :failed, error: e}          -> {:failed, e}
      _                                     -> :pending
    end
  end)
# caller receive-loops until it sees a non-:pending value,
# then AgentServer.unsubscribe(pid, ref)
```

`:domain` is whatever the agent declared via `path:` per [ADR 0014](0014-slice-middleware-plugin.md). Substitute the agent's actual path.

FSM agents with `:won`/`:lost`/`:cancelled` plug in with the obvious selector — the hardcoded-atoms problem dissolves.

### What's intentionally *not* in this design

- **No `signal_emissions/0` callback.** Subscription points are input signal types. Nothing new to declare; `signal_routes` is already the public vocabulary.
- **No changes to `Jido.Actions.Status`.** `MarkCompleted` and `MarkFailed` keep writing terminal status into their slice. The subscribe primitive observes those state transitions via the caller's selector; no special emission needed.
- **No new lifecycle signal** for work completion. [ADR 0015](0015-agent-start-is-signal-driven.md)'s three lifecycle signals (`starting`, `ready`, `stopping`) cover process lifetime. Work completion is observed via selector on state, orthogonal to process lifetime.
- **No state leakage.** The selector's return is author-chosen and typically small. The state struct never crosses the boundary.
- **No change to `Jido.Signal.Call.call/3`.** It's a different job (request/reply with author-shaped payload via `%Directive.Reply{}`). Coexists.
- **No interaction with middleware internals.** The primitives live on AgentServer outside the chain. Middleware authors don't see them; ack/subscribe authors don't see middleware.

## Consequences

- Three overlapping waiting mechanisms collapse to two primitives, plus two surviving helpers: `Jido.Signal.Call.call/3` for request/reply with `%Directive.Reply{}`, and `AgentServer.state/1` kept per [ADR 0006](0006-external-sync-uses-signals.md) for liveness and bootstrap.

- The paths-vs-values asymmetry of `await_completion/2` dissolves. Callers pass a selector that encodes whatever matching logic they want.

- Minimal boundary data. The selector's return is typically small; full state never crosses the boundary.

- Input-signal-type vocabulary stays single-sourced at `signal_routes`. No declared-emissions callback to maintain.

- Atomic registration. `cast_and_await/4` writes the ack entry before any middleware runs, addressing the "subscribed too late" race [ADR 0006](0006-external-sync-uses-signals.md) flagged for subscribe-then-block alternatives.

- Caller death handled by monitor + DOWN handler, same shape as today's `completion_waiters`.

- **Clean layering.** Ack/subscribe live at the AgentServer/mailbox boundary; middleware lives inside the pipeline. The two don't interact. A middleware author can't break ack semantics; an ack user can't observe middleware internals. This is the main reason to place the hook outside the chain rather than inside the innermost layer.

- **Retry is transparent.** `Retry` middleware re-invoking `next` runs the pipeline N times, but the ack fires once (on the outermost return). Selectors see the final state after all retries. Callers get "did it eventually succeed" without needing to know how many retries happened.

- **Swallow is transparent too.** A middleware that rejects a signal (by not calling `next`) leaves state untouched. The selector runs against that untouched state. If the caller wants to know "did my signal actually do anything," they encode that question in the selector — typically by looking for a state delta the actions would have produced. The primitives stay minimal.

- `Jido.Await.completion/3` keeps its public shape. Internally it becomes a thin wrapper over `cast_and_await/4` with a default selector matching `:completed`/`:failed` in the agent's declared domain path. Callers with FSM-style terminals pass their own selector.

- `Jido.Await.all/3` / `any/3` keep their shapes, rewired to use the new primitives underneath.

- `AgentServer.await_completion/2` and `state.completion_waiters` retire — the primitive is replaced, not patched.

- [ADR 0006](0006-external-sync-uses-signals.md)'s deferred `stream_status/2` helper can be rebuilt on `subscribe/4` with a selector over the status snapshot.

- `process_signal_sync/2` / `process_signal_async/2` naming is confusing post-[0009](0009-inline-signal-processing.md) but not changed by this ADR. Housekeeping item for a separate PR.

## Alternatives considered

- **Fire ack inside the innermost middleware (before chain unwinds).** Smaller internal change; the hook point is wherever the core pipeline lives. Rejected: couples ack semantics to middleware authoring. Post-`next` transformations in middleware (retry, error conversion, persist-after) wouldn't be visible to ack selectors. The outer-boundary placement is what makes ack/subscribe composable with the middleware chain rather than subordinate to it.

- **Patch `await_completion/2` with `completed_values:` / `failed_values:` options.** Smallest delta. Fixes the FSM-agent case without adding primitives. Preserves three overlapping waiting mechanisms. Rejected: tactical, doesn't unify.

- **Ack payload = emitted-signal list.** Earlier drafts had the ack carry every signal the processing emitted. Pushes large data across the boundary and introduces a second vocabulary (output signals as a distinct concept). Selector-based ack is smaller.

- **Redux-style fire-on-change semantics.** The runtime tracks last-seen selector return per subscriber and only fires when it changes. More aligned with `useSelector`. Adds per-subscriber bookkeeping; the selector must run on every signal regardless. Fire-on-every-match is simpler; callers who want change detection filter client-side. Can be added as opt-in later.

- **Transitive-closure ack.** Wait until the input signal AND all signals it causes (loop-backs, async results, downstream cmds) are fully settled. Hard to define, hard to implement, hard to reason about. Per-signal ack is bounded and sufficient.

- **`subscribe/4` only, drop `cast_and_await/4`.** Use subscribe + caller-side receive-one filtering for everything. Re-introduces the subscribe-too-late race for per-signal waits. `cast_and_await/4` registers atomically with the cast; the race is gone by construction. Keep both.

- **Named error contract for middleware swallow (`{:error, :swallowed_by_middleware}`).** Makes "did middleware reject my signal" visible to the caller. Rejected: introduces a new vocabulary term (`:swallowed_by_middleware`) across the ack protocol, couples ack to middleware behaviour, and still doesn't tell the caller *which* middleware swallowed or why. The selector-based model keeps the protocol minimal and lets callers shape the question themselves.
