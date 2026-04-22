# 0010. Waiting on agents uses per-signal ack + subscribe, selector-based

- Status: Proposed
- Implementation: Pending
- Date: 2026-04-22
- Related commits: —

## Context

Three overlapping mechanisms exist today for "hear back from an
agent":

- `Jido.AgentServer.await_completion/2`
  ([agent_server.ex:369-412](../../lib/jido/agent_server.ex)) parks a
  waiter on `state.completion_waiters` and wakes it when the agent's
  state reaches a terminal status. The caller configures *paths*
  (`status_path`/`result_path`/`error_path`, defaulting to the
  `:__domain__` slice per ADR 0008) but not *values* — the terminal
  atoms `:completed`/`:failed` are hardcoded at
  [agent_server.ex:2310-2321](../../lib/jido/agent_server.ex). FSM
  agents with richer terminal atoms (`:won`/`:lost`/`:cancelled`)
  can't plug in without a wrapper action that maps their domain
  atoms onto the Jido sentinels.
- `Jido.Signal.Call.call/3` (ADR 0002) — a correlation-id receive
  loop that casts a query signal with
  `jido_dispatch: {:pid, target: self()}` and waits for a reply
  signal whose `subject` matches the request's id. Actions must opt
  in by emitting a `%Directive.Reply{}` (or `Signal.Call.reply/3`);
  if they forget, the caller hangs until timeout.
- `Jido.AgentServer.call/2` — a `GenServer.call` that dispatches the
  signal synchronously and returns `{:ok, %State{}}`. Leaks the full
  state struct, the exact ADR 0002 anti-pattern.

There is **no subscribe/unsubscribe primitive**. Fan-out
observability requires either (a) the emitter to know about
subscribers up-front via `%Directive.Emit{dispatch: {:pid, target:
pid}}` / `{:pubsub, topic: t}`, or (b) an out-of-band PubSub topic
the author happens to broadcast to. There is no way for a consumer
to join an agent's output stream after the fact.

ADR 0002 (don't leak state; let agents shape replies), ADR 0003
(server-state reads live at the directive layer), ADR 0006 (external
sync uses signals and events, not state-dig or polling), and ADR 0009
(signals are the correlation channel) each constrain the shape of
"hear back." The three current mechanisms each honour some but not
all of those constraints. We want one design that honours all of
them.

### Note on function names in the current code

`process_signal_async/2`
([agent_server.ex:1538](../../lib/jido/agent_server.ex)) and
`process_signal_sync/2`
([agent_server.ex:1459](../../lib/jido/agent_server.ex)) refer to the
**caller's** dispatch convention (the `handle_cast`/`handle_info`
path vs. the `handle_call` path), not to the processing model.
Per ADR 0009 the processing itself is always inline, sharing
`process_signal_common/2`. The `_sync`/`_async` suffix is a rename
candidate — housekeeping, not scope of this ADR.

## Decision

Introduce two primitives on `Jido.AgentServer`. Both take a
caller-provided selector that runs **in the agent process** and
returns the value to push back. The selector's return is the only
thing that crosses the process boundary.

### 1. `cast_and_await/4` — per-signal ack with selector

    @spec cast_and_await(server(), Signal.t(), selector :: (map -> any),
                         opts :: keyword()) ::
            {:ok, any()} | {:error, term()}

- The caster registers an ack entry **before** the signal is
  dispatched into the processing pipeline. Entry keyed on
  `signal.id`:

      state.pending_acks :: %{signal_id => %{
        caller_pid, ref, monitor_ref, selector
      }}

  Registration is synchronous with the cast so there's no
  subscribe-too-late race — the ack is present before
  `process_signal_common/2` starts.

- After `execute_directives/3` returns for that specific signal
  inside the processing pipeline, the runtime looks up the ack entry
  by `signal.id`, runs `selector.(state.agent.state)` in-process,
  sends `{:jido_ack, ref, {:ok, selector_return}}` to `caller_pid`,
  and removes the entry.

- On plugin-hook / routing / directive failure, the selector is not
  invoked; the caller receives
  `{:jido_ack, ref, {:error, reason}}`.

- Timeout on the caller side cancels the ack entry (`GenServer.cast
  {:cancel_ack, ref}` — same pattern as
  [agent_server.ex:400-411](../../lib/jido/agent_server.ex)'s
  `:cancel_await_completion`).

- Bounded scope: this ack is for the input signal + its direct
  directives. Loop-back signals (emitted via
  `%Directive.Emit{dispatch: nil}`) and async-result signals are
  **separate** processing cycles with their own acks available.

### 2. `subscribe/4` + `unsubscribe/2` — ambient subscribe with selector

    @spec subscribe(server(), signal_pattern :: term(),
                    selector :: (map -> any), opts :: keyword()) ::
            {:ok, sub_ref :: reference()} | {:error, term()}

    @spec unsubscribe(server(), sub_ref :: reference()) :: :ok

- Subscriber entries:

      state.signal_subscribers :: %{sub_ref => %{
        pattern_compiled, selector, dispatch, monitor_ref
      }}

- `pattern` uses the same router matching the agent already uses for
  `signal_routes/0` — exact type, wildcard (`"work.*"`), or
  `{path, match_fn}` tuples. Subscription points are the **input**
  signal types the agent already declares it consumes. No new
  vocabulary; nothing to declare separately.

- At the end of every signal's processing (same hook point as the
  ack primitive), iterate subscribers; for each whose pattern
  matches the input signal type, run `selector.(state.agent.state)`
  in-process and dispatch the result via its dispatch config.
  Default dispatch: `{:pid, target: self()}`, delivered as
  `{:jido_subscription, sub_ref, %{signal_type: t, value:
  selector_return}}`.

- Pattern matching runs before selector runs; non-matching signals
  neither invoke the selector nor cross the boundary.

- Subscribers are monitored; DOWN drops the entry.

### Error handling

If the selector raises, log it (with the subscriber/ack ref for
traceability) and send an error variant to the caller. A crashing
selector must not kill the agent.

### Example — completion waits under the new primitives

    # Single-cast completion — wait for one signal's processing
    {:ok, {:completed, answer}} =
      AgentServer.cast_and_await(pid, Signal.new!("work.start", %{}),
        fn s ->
          case s.__domain__ do
            %{status: :completed, last_answer: r} -> {:completed, r}
            %{status: :failed, error: e}          -> {:failed, e}
            _                                      -> :not_terminal
          end
        end)

    # Multi-signal completion — observe any processing until terminal
    {:ok, ref} = AgentServer.subscribe(pid, "*",
      fn s ->
        case s.__domain__ do
          %{status: :completed, last_answer: r} -> {:completed, r}
          %{status: :failed, error: e}          -> {:failed, e}
          _                                      -> :pending
        end
      end)
    # caller receive-loops until it sees a non-:pending value,
    # then AgentServer.unsubscribe(pid, ref)

FSM agents with `:won`/`:lost`/`:cancelled` plug in with the obvious
selector — the hardcoded-atoms problem dissolves.

### What's intentionally *not* in this design

- **No `signal_emissions/0` callback.** Subscription points are
  input signal types. Nothing new to declare; `signal_routes/0` is
  already the public vocabulary.
- **No changes to `Jido.Actions.Status`.** `MarkCompleted` and
  `MarkFailed` keep writing terminal status into the `:__domain__`
  slice. The subscribe primitive observes those state transitions
  via the caller's selector; no special emission needed.
- **No new lifecycle signal** (e.g. `jido.agent.work.completed`).
  ADR 0007's three lifecycle signals stay untouched. Work
  completion is observed via selector on state, orthogonal to
  process lifetime.
- **No state leakage.** The selector's return is author-chosen and
  typically small. The state struct never crosses the boundary.
- **No change to `Jido.Signal.Call.call/3`.** It's a different job
  (request/reply with author-shaped payload via
  `%Directive.Reply{}`). Coexists with the new primitives.

## Consequences

- Three overlapping waiting mechanisms collapse to two primitives,
  plus two surviving helpers: `Jido.Signal.Call.call/3` for
  request/reply with `%Directive.Reply{}`, and
  `AgentServer.state/1` kept per ADR 0006 for liveness and
  bootstrap.
- The paths-vs-values asymmetry of `await_completion/2` dissolves.
  Callers pass a selector that encodes whatever matching logic they
  want.
- Minimal boundary data. The selector's return is typically small;
  full state never crosses the boundary.
- Input-signal-type vocabulary stays single-sourced at
  `signal_routes/0`. No declared-emissions callback to maintain.
- Atomic registration. `cast_and_await/4` writes the ack entry
  before the processing pipeline starts, addressing the
  "subscribed too late" race ADR 0006 flagged for subscribe-then-
  block alternatives.
- Caller death handled by monitor + DOWN handler, same shape as
  today's `completion_waiters`.
- `Jido.Await.completion/3` keeps its public shape. Internally it
  becomes a thin wrapper over `cast_and_await/4` with a default
  selector matching `:completed`/`:failed` in the `:__domain__`
  slice. Callers with FSM-style terminals pass their own selector.
- `Jido.Await.all/3` / `any/3` keep their shapes, rewired to use
  the new primitives underneath.
- `AgentServer.await_completion/2` and
  `state.completion_waiters` retire — the primitive is replaced,
  not patched.
- ADR 0006's deferred `stream_status/2` helper can be rebuilt on
  `subscribe/4` with a selector over the status snapshot. This is
  the concrete refill for the "long-lived signal subscription"
  that ADR 0006 called out as worth revisiting.
- `process_signal_sync/2` / `process_signal_async/2` naming is
  confusing post-ADR-0009 but not changed by this ADR. Housekeeping
  item for a separate PR.
- No breaking change to the public moduledocs' intent. The
  `Jido.AgentServer` "Completion Detection" and `Jido.Await`
  "Completion Convention" anti-patterns fixed in a separate doc
  pass are consistent with this ADR either way.

## Alternatives considered

- **Patch `await_completion/2` with `completed_values:` /
  `failed_values:` options.** Smallest delta. Fixes the FSM-agent
  case without adding primitives. Preserves three overlapping
  waiting mechanisms. Rejected: tactical, doesn't unify, and the
  resulting API is still state-watching instead of signal-aware.

- **Ack payload = emitted-signal list.** Earlier drafts of this
  design had the ack carry every signal the processing emitted.
  Pushes large data across the boundary and introduces a second
  vocabulary (output signals as a distinct concept, implying a
  declared-emissions callback symmetric to `signal_routes/0`).
  Selector-based ack with input-signal subscription points is
  smaller, simpler, and doesn't require new declarative surface.

- **Redux-style state-projection with fire-on-change semantics.**
  The runtime tracks last-seen selector return per subscriber and
  only fires when it changes. More aligned with `useSelector`.
  Adds per-subscriber bookkeeping; the selector must run on every
  cmd/2 regardless. Fire-on-every-match is simpler; callers who
  want change detection filter client-side. Can be added as an
  opt-in later without breaking the primitive.

- **Transitive-closure ack.** Wait until the input signal AND all
  signals it causes (loop-backs, async results, downstream cmds) are
  fully settled. Hard to define ("when is done done?"), hard to
  implement, hard to reason about. Per-signal ack is bounded and
  sufficient.

- **Implement `subscribe/4` and drop `cast_and_await/4`.** Use
  `subscribe` + caller-side receive-one filtering for everything.
  Re-introduces the subscribe-too-late race for per-signal waits
  (the subscriber's pattern would register after the cast, missing
  the event if processing is fast). `cast_and_await/4` registers
  the ack atomically with the cast; the race is gone by
  construction. Keep both.
