# Task 0007 — `cast_and_await/4` + `subscribe/4` primitives; delete `Jido.Await` entirely

- Commit #: 7 of 9
- Implements: [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md) — waiting via ack + subscribe on AgentServer
- Depends on: 0000, 0001, 0002, 0003, 0004 (needs the middleware chain to define "outermost"), 0006
- Blocks: 0008
- Leaves tree: **red** (Await tests still reference the deleted module until C8)

## Goal

Replace every waiting mechanism in the codebase with two selector-based primitives on `Jido.AgentServer`:

1. **`cast_and_await/4`** — per-signal ack. Caller registers synchronously with the cast; after the outermost middleware unwinds, AgentServer runs the selector on agent state and delivers the result to the caller.
2. **`subscribe/4`** + **`unsubscribe/2`** — ambient subscribe on a signal pattern + selector. Matching signals fire the selector; `{:ok, value}`/`{:error, reason}` cross the boundary; `:skip` keeps listening.

**Delete everything that wraps these** (per W6 resolution):

- `lib/jido/await.ex` — all of it. Zero real consumers in `lib/`; opinionated policy (terminal status convention).
- `Jido.completion/3`, `Jido.all/3`, `Jido.any/3` in [lib/jido.ex](../../lib/jido.ex).
- `AgentServer.await_completion/2` and `state.completion_waiters`.
- `AgentServer.await_child/3` rewrites as a thin wrapper over `subscribe/4`; `state.child_waiters` field deleted.
- `AgentServer.call/2` variant that returns `{:ok, %State{}}` (state-leaking; per [ADR 0002](../adr/0002-signal-based-request-reply.md)'s critique). `AgentServer.state/1` kept per [ADR 0006](../adr/0006-external-sync-uses-signals.md).

`Jido.Signal.Call.call/3` coexists unchanged (request/reply via `%Directive.Reply{}`).

## Files to modify

### `lib/jido/agent_server.ex`

#### New state fields

```elixir
# On %State{}:
pending_acks :: %{Jido.Signal.id() => %{
  caller_pid: pid(),
  ref: reference(),
  monitor_ref: reference(),
  selector: (map() -> {:ok, term()} | {:error, term()})
}}

signal_subscribers :: %{reference() => %{
  pattern_compiled: term(),
  selector: (map() -> {:ok, term()} | {:error, term()} | :skip),
  dispatch: term(),
  monitor_ref: reference(),
  once: boolean()   # if true, unsubscribe after the first :ok or :error fire
}}
```

Populate as empty maps in `State.from_options/3`.

**Also deleted from `%State{}`**:
- `completion_waiters` ([agent_server/state.ex:95-97](../../lib/jido/agent_server/state.ex))
- `child_waiters` ([agent_server/state.ex:98-103](../../lib/jido/agent_server/state.ex))

#### `cast_and_await/4`

```elixir
@type ack_selector :: (map() -> {:ok, term()} | {:error, term()})

@spec cast_and_await(server(), Signal.t(), ack_selector(), keyword()) ::
        {:ok, term()} | {:error, term()}
def cast_and_await(server, %Signal{} = signal, selector, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 5_000)
  pid = resolve_pid(server)
  ref = make_ref()

  # Register BEFORE cast so there's no race — atomic via GenServer.call.
  :ok = GenServer.call(pid, {:register_ack, signal.id, selector, self(), ref})
  :ok = GenServer.cast(pid, {:signal, signal})

  receive do
    {:jido_ack, ^ref, {:ok, _} = result} -> result
    {:jido_ack, ^ref, {:error, _} = result} -> result
    {:DOWN, _, :process, ^pid, reason} -> {:error, {:agent_down, reason}}
  after
    timeout ->
      GenServer.cast(pid, {:cancel_ack, ref})
      {:error, :timeout}
  end
end
```

**Selector contract for ack**: returns `{:ok, value} | {:error, reason}`. No `:skip` — the ack fires exactly once per signal, so there's nothing to defer to. If the selector raises, the agent process crashes (standard OTP) and the caller's DOWN monitor converts it to `{:error, {:agent_down, reason}}`. No special-case wrapper.

The `{:register_ack, ...}` handle_call monitors the caller (DOWN removes the entry) and writes to `state.pending_acks[signal.id]`.

**Ack firing point:** in the signal-handling flow, after the middleware chain returns its `{new_ctx, directives}` and those directives have been executed — at the moment `process_signal_async/2` (or `process_signal_sync/2`) is about to return to the GenServer loop. See [agent_server.ex:1483-1505](../../lib/jido/agent_server.ex) for the current seam; the new hook point lives *outside* the chain, after `execute_directives/3` completes.

```elixir
defp fire_ack_for_signal(state, %Signal{id: id}) do
  case Map.pop(state.pending_acks, id) do
    {nil, acks} -> {state, acks}
    {ack, acks} ->
      # Selector's tagged-tuple return ({:ok, _} | {:error, _}) passes through verbatim.
      result = ack.selector.(state.agent.state)
      send(ack.caller_pid, {:jido_ack, ack.ref, result})
      Process.demonitor(ack.monitor_ref, [:flush])
      {%{state | pending_acks: acks}, acks}
  end
end
```

**Selector contract**: a pure function `state -> {:ok, value} | {:error, reason}`. No try/rescue wraps it — if a selector raises, standard OTP applies: the agent process crashes, the caller's DOWN monitor fires, `cast_and_await` returns `{:error, {:agent_down, reason}}`. Authors keep selectors tiny and non-raising; selectors are not an appropriate place to execute effectful or fallible code.

**Retry semantics:** if retry-middleware re-invokes `next` three times, the outermost middleware returns once. Ack fires once per the outermost return. This is the entire point of placing the hook outside the chain — the caller sees "final state after all retries."

**Error semantics:** if the middleware chain raises, the catch-block at [line 1519-1534](../../lib/jido/agent_server.ex) converts it to an error reply. For ack: `send(caller, {:jido_ack, ref, {:error, reason}})`. Selector is not invoked in this case.

**Stop semantics:** if `execute_directives/3` returns `{:stop, reason, state}` (an action emitted `%Directive.Stop{}`, or a middleware converted an error into a stop), the ack is **not** separately fired. The caller's `Process.monitor` on the GenServer receives `{:DOWN, ref, :process, pid, reason}`, which the `cast_and_await` receive clause handles by returning `{:error, {:agent_down, reason}}`. Rationale: the DOWN path already exists and handles this cleanly; adding a dedicated `{:error, :agent_stopping}` ack variant would duplicate the surface without giving the caller new information. Callers distinguish "signal failed but agent lives" from "signal caused agent stop" by the return value: `{:error, _}` vs `{:error, {:agent_down, _}}`.

#### `subscribe/4` and `unsubscribe/2`

```elixir
@type subscribe_selector :: (map() -> {:ok, term()} | {:error, term()} | :skip)

@spec subscribe(server(), pattern :: term(), subscribe_selector(), keyword()) ::
        {:ok, reference()} | {:error, term()}
def subscribe(server, pattern, selector, opts \\ []) do
  dispatch = Keyword.get(opts, :dispatch, {:pid, target: self()})
  once? = Keyword.get(opts, :once, false)
  GenServer.call(resolve_pid(server), {:subscribe, pattern, selector, dispatch, self(), once?})
end

@spec unsubscribe(server(), reference()) :: :ok
def unsubscribe(server, sub_ref) do
  GenServer.cast(resolve_pid(server), {:unsubscribe, sub_ref})
end
```

The `:subscribe` call compiles the pattern via the existing `Jido.Signal.Router` matcher (same one used for `signal_routes`), monitors the caller, and returns a `sub_ref :: reference()`.

**Selector contract for subscribe**:
- `{:ok, value}` → fire `{:jido_subscription, ref, {:ok, value}}` to caller; if `once: true`, unsubscribe and stop monitoring.
- `{:error, reason}` → fire `{:jido_subscription, ref, {:error, reason}}` to caller; if `once: true`, unsubscribe.
- `:skip` → silent. Subscription stays alive. `once: true` does NOT trigger on skip.

If the selector raises, the agent process crashes (standard OTP). The caller's DOWN monitor converts this to an agent-stop error; no dedicated selector-raised variant ships.

**Matching / dispatch firing point:** same as ack — after the outermost middleware unwinds. Iterate `state.signal_subscribers`; for each subscriber whose `pattern_compiled` matches the input signal's type, run the selector in-process and dispatch the return via `Jido.Signal.Dispatch.dispatch/2` (or an inline helper for the `{:pid, target:}` default).

```elixir
defp fire_subscribers(state, %Signal{type: type} = signal) do
  Enum.reduce(state.signal_subscribers, state, fn {ref, entry}, acc_state ->
    if matches?(entry.pattern_compiled, type, signal) do
      # Selector is a pure function returning {:ok, _} | {:error, _} | :skip. No try/rescue.
      result = entry.selector.(acc_state.agent.state)

      case result do
        :skip ->
          acc_state

        {:ok, _value} = fire ->
          dispatch_subscriber(entry.dispatch, ref, type, fire)
          if entry.once, do: remove_subscriber(acc_state, ref), else: acc_state

        {:error, _reason} = fire ->
          dispatch_subscriber(entry.dispatch, ref, type, fire)
          if entry.once, do: remove_subscriber(acc_state, ref), else: acc_state
      end
    else
      acc_state
    end
  end)
end

defp dispatch_subscriber({:pid, target: target}, ref, type, result) do
  send(target, {:jido_subscription, ref, %{signal_type: type, result: result}})
end
```

Pattern compiler and matcher reuse the existing `Jido.Signal.Router` internals. No new vocabulary.

#### Delete

- `await_completion/2` at [line 393-413](../../lib/jido/agent_server.ex)
- `handle_call({:await_completion, opts}, from, state)` at [line 1118+](../../lib/jido/agent_server.ex)
- `handle_cast({:cancel_await_completion, waiter_id}, state)` at [line 1277+](../../lib/jido/agent_server.ex)
- `maybe_notify_completion_waiters/1` at [line 2323-2353](../../lib/jido/agent_server.ex), and all call sites (two, at [line 1629, 1655](../../lib/jido/agent_server.ex))
- `completion_waiters` field from `%State{}` ([agent_server/state.ex:95-97](../../lib/jido/agent_server/state.ex))
- `handle_call({:await_child, ...})` at [agent_server.ex:1148+](../../lib/jido/agent_server.ex), `handle_cast({:cancel_await_child, ...})` at [line 1291+](../../lib/jido/agent_server.ex), `maybe_notify_child_waiters/3` at [line 1736+](../../lib/jido/agent_server.ex)
- `child_waiters` field from `%State{}` ([agent_server/state.ex:98-103](../../lib/jido/agent_server/state.ex))
- `AgentServer.call/2` variant that returns `{:ok, %State{}}` (the state-leaking one from [ADR 0002](../adr/0002-signal-based-request-reply.md) critique). Keep `AgentServer.state/1` for liveness and bootstrap per [ADR 0006](../adr/0006-external-sync-uses-signals.md).

#### `await_child/3` rewrite

Keeps the public API; rewrites internals to use `subscribe/4` with `once: true`:

```elixir
def await_child(server, child_tag, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, Defaults.agent_server_await_timeout_ms())

  with {:ok, pid} <- resolve_server(server) do
    # Fast path: if the tag is already present, return immediately without subscribing.
    case GenServer.call(pid, {:get_child_pid, child_tag}) do
      {:ok, child_pid} -> {:ok, child_pid}

      :not_found ->
        selector = fn state ->
          case state.children do
            %{^child_tag => %ChildInfo{pid: child_pid}} -> {:ok, child_pid}
            _ -> :skip
          end
        end

        case subscribe(pid, "jido.agent.child.started", selector, once: true) do
          {:ok, ref} -> wait_once(pid, ref, timeout)
          error -> error
        end
    end
  end
end

defp wait_once(server, ref, timeout) do
  receive do
    {:jido_subscription, ^ref, %{result: {:ok, value}}} -> {:ok, value}
    {:jido_subscription, ^ref, %{result: {:error, reason}}} -> {:error, reason}
  after
    timeout ->
      unsubscribe(server, ref)
      {:error, :timeout}
  end
end
```

Needs a new handler `handle_call({:get_child_pid, tag}, from, state)` returning `{:ok, pid}` or `:not_found`.

#### Delete `Jido.Await` entirely

- Delete [lib/jido/await.ex](../../lib/jido/await.ex) — the whole module
- Delete `Jido.completion/3`, `Jido.all/3`, `Jido.any/3` in [lib/jido.ex:680-730](../../lib/jido.ex) (the wrappers around `Jido.Await.*`)
- Users who want "wait for terminal" write their own helper. Example snippet lives in C8's migration guide.

#### DOWN handler

[line 1348-1360](../../lib/jido/agent_server.ex) currently cleans up `completion_waiters` and `child_waiters`. Update to clean up `pending_acks` (by `monitor_ref`) and `signal_subscribers` (by `monitor_ref`) instead. Both maps indexed by their refs for O(1) caller-death cleanup.

### `lib/jido/await.ex` — **deleted in its entirety**

Module + all public functions (`completion/3`, `all/3`, `any/3`, `child/4`, `get_children/1`, `alive?/1`, `cancel/2`) deleted. The "wait for terminal" convention is not framework infrastructure.

Users who want it write a ~10-line helper over `subscribe/4`:

```elixir
defmodule MyApp.Await do
  def completion(server, timeout \\ 5_000) do
    selector = fn state ->
      case state.domain do
        %{status: :completed, last_answer: r} -> {:ok, %{status: :completed, result: r}}
        %{status: :failed, error: e}          -> {:ok, %{status: :failed, result: e}}
        _                                     -> :skip
      end
    end

    {:ok, ref} = AgentServer.subscribe(server, "*", selector, once: true)

    receive do
      {:jido_subscription, ^ref, %{result: {:ok, value}}} -> {:ok, value}
    after
      timeout ->
        AgentServer.unsubscribe(server, ref)
        {:error, :timeout}
    end
  end
end
```

This snippet lives in C8's migration guide for users who need the old behavior.

## Files to create

None. The ack/subscribe primitives live on `Jido.AgentServer` directly.

## Acceptance

- `mix compile --warnings-as-errors` passes
- `cast_and_await/4` fires once even when middleware retries `next` three times — verified by scratch script with a Retry-style middleware that calls `next` three times on a specific signal type.
- `subscribe/4` with pattern `"work.*"` receives one `{:jido_subscription, ref, %{signal_type: "work.start", value: ...}}` per matching signal.
- `unsubscribe/2` drops the entry; subsequent signals of the same pattern don't fire the selector.
- DOWN monitor: kill the caller of `cast_and_await/4`; confirm the ack entry is cleaned from `state.pending_acks` (inspect via `Jido.AgentServer.state/1`).
- Selector raise: confirm the agent process crashes cleanly (no try/rescue shield); the caller's DOWN monitor produces `{:error, {:agent_down, _}}`.
- `mix test` — **expect failures** in:
  - `test/jido/await_test.exs` (354 lines) — shapes mostly compatible but receive-loop mechanics differ
  - `test/jido/await_coverage_test.exs` — same
  - Any test that called `AgentServer.call/2` expecting `{:ok, %State{}}` — retired in C8

## Out of scope

- Telemetry instrumentation for new primitives — can be added later; scope of this PR just has the primitives themselves.
- `subscribe/4` opt-in change-detection (fire only on selector-value-change) — ADR 0016 notes this as a potential future addition, not this PR.
- Grouped ack (wait until a signal AND all its loop-backs settle) — explicitly rejected by ADR 0016.

## Risks

- **Ack registration race**: the cast is asynchronous, but the ack must be in place before the signal reaches any middleware. This is why `{:register_ack, ...}` is a `GenServer.call` rather than a cast — it synchronizes. Even if the caller crashes between call and cast, the monitor cleanup handles it.
- **Hook placement**: "after the outermost middleware unwinds" is distinct from "inside the innermost layer." Implement by wrapping the entire chain call in a helper that fires acks/subscribers on return:

  ```elixir
  {new_ctx, dirs} = state.middleware_chain.(signal, ctx)
  state_with_agent = %{state | agent: new_ctx.agent}
  {:ok, executed_state} = execute_directives(dirs, signal, state_with_agent)
  executed_state = fire_ack_for_signal(executed_state, signal)
  executed_state = fire_subscribers(executed_state, signal)
  ```

  The order matters: ack fires before subscribers (deterministic, easier to reason about).
- **Selector-in-process semantics**: the selector runs synchronously in the agent process. A slow selector blocks the mailbox; a raising selector crashes the agent. The ADR accepts both — authors should keep selectors tiny and pure. No try/rescue wraps the selector (standard OTP crash behavior applies; the caller's DOWN monitor recovers `cast_and_await`).
- **Matching `pattern: "*"`**: this is a wildcard match everything pattern. The existing Router likely has canonical handling for `*` vs `path.*` — mirror it so subscribe semantics are identical to signal_route semantics.
- **Retiring `completion_waiters`**: any telemetry or debug tooling that inspected this field breaks. Search `lib/` and `test/` for the field name; update or remove.
