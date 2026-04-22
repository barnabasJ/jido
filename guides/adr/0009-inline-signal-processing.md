# 0009. Inline signal processing; signals are the only async-completion vehicle

- Status: Accepted
- Date: 2026-04-22
- Supersedes: Task-offload aspect of [0002](0002-signal-based-request-reply.md) (the public `Signal.Call.call/3` API is unchanged)

## Context

Before this ADR, `Jido.AgentServer` layered **three explicit queues** plus a drain-loop on top of the Erlang mailbox:

- `queue` — directive FIFO, drained one item per `:drain` self-send
- `signal_call_queue` — pending sync `Signal.Call` requests waiting for the in-flight one
- `deferred_async_signals` — async signals buffered while a sync call's Task was computing

Those structures existed as scaffolding around a `Task` offload for sync calls. On inspection, the Task offload was **offloading the cheap work while the only potentially slow work ran inline regardless**:

- `cmd/2` is pure state mutation + directive emission — fast by design.
- Plugin signal hooks are typically pattern-matching — fast.
- Signal routing is a trie lookup — fast.
- The Task wrapped exactly these three steps, then sent `{:signal_call_result, ref, result}` back. Directives were then enqueued and drained by the GenServer itself — not inside the Task.

So the Task offload was:

- **Unnecessary for the fast path** — `cmd/2` doesn't need process isolation.
- **Unhelpful for the slow path** — directives that need to do I/O had their own mechanism (return `{:async, ref, state}` + spawn a task), and the Task offload didn't cover directive execution anyway.

The `:drain` loop compounded the complexity: directives were queued, then processed one per mailbox round-trip, which meant a signal arriving mid-drain could see a **partial prefix** of the previous signal's state updates.

## Decision

Drop all three queues, the drain loop, and the Task offload. Process every signal inline inside its triggering GenServer handler. The Erlang mailbox is the only queue.

Unify the `DirectiveExec` return shape so every directive returns `{:ok, state}` (or `{:stop, reason, state}` for abnormal termination). The previous `{:async, ref | nil, state}` variant is removed. Async effects are expressed the Jido way: **spawn a task, write a loading marker into state, emit a signal when the task finishes.**

### Target architecture

```elixir
# handle_call / handle_cast / handle_info all share the same core pipeline.
def handle_call({:signal, %Signal{} = signal}, _from, state) do
  {traced, _} = TraceContext.ensure_from_signal(signal)
  try do
    {:reply, reply, state} = process_signal_sync(traced, state)
    {:reply, reply, state}
  after
    TraceContext.clear()
  end
end

def handle_cast({:signal, %Signal{} = signal}, state) do
  {traced, _} = TraceContext.ensure_from_signal(signal)
  try do
    case process_signal_async(traced, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:stop, reason, new_state} -> {:stop, reason, new_state}
    end
  after
    TraceContext.clear()
  end
end
```

Both paths run through one inline pipeline:

1. Plugin signal hooks (`run_plugin_signal_hooks/2`)
2. Routing (or override target from hooks)
3. `Agent.cmd/2` to get directives
4. **Execute every returned directive inline, in order**, via `execute_directives/3`
5. Notify completion waiters
6. Return (sync path replies with transformed agent; async path just returns `{:noreply, state}`)

`execute_directives/3` is a tight recursive loop — no yield, no self-send, no state-queue:

```elixir
def execute_directives([], _signal, state), do: {:ok, state}

def execute_directives([d | rest], signal, state) do
  case exec_directive_with_telemetry(d, signal, state) do
    {:ok, new_state} ->
      execute_directives(rest, signal, maybe_notify_completion_waiters(new_state))

    {:stop, reason, new_state} ->
      warn_if_normal_stop(reason, d, new_state)
      {:stop, reason, new_state}
  end
end
```

### The DirectiveExec protocol collapses to one return shape

Before:

- `{:ok, state}` — sync, continue
- `{:async, ref | nil, state}` — async, continue (ref unused in practice; `Emit` always passed `nil`)
- `{:stop, reason, state}` — stop

After:

- `{:ok, state}` — continue (state is already updated synchronously; may contain a loading marker if the directive kicked off async work)
- `{:stop, reason, state}` — stop

The async variant is gone because **it was introducing a second coordination channel alongside signals**. With it removed:

- **One correlation system.** A directive that wants async work spawns a task and has the task emit a **signal** back to the agent when done. That signal flows through the normal pipeline (plugin hooks → routing → `cmd/2`) and a `cmd/2` clause settles whatever loading marker the directive planted.
- **No `ref` to manage.** The state path where the loading marker lives *is* the correlation key, in the RTK-Query style. The task's completion signal carries the same key back through its payload, and `cmd/2` writes `:success` or `:error` at that path.
- **Uniform telemetry, tracing, debug, plugin-hooks.** The completion message is just a signal; everything that works for inbound signals works for it.

Today's built-in directives all fit this shape cleanly:

- `Emit` (local): `send(self(), {:signal, signal})` — already the "emit a signal back" pattern. Returns `{:ok, state}`.
- `Emit` (external dispatch): `Task.Supervisor.start_child(…)` fire-and-forget. Returns `{:ok, state}`.
- `Schedule`, `Spawn`, `SpawnAgent`, `SpawnManagedAgent`, `StopChild`, `AdoptChild`, `Reply`, `Stop`, `Error`, fallback `Any` — all fast and return `{:ok, state}` (or `{:stop, ...}` for `Stop` / `Error` under `:stop_on_error`).
- `RunInstruction`: still runs `Jido.Exec.run/1` synchronously today — a pre-existing bug unchanged by this refactor. The correct fix (follow-up) is to have it spawn a task, write a loading marker into domain state, return `{:ok, state_with_marker}`, and have the task emit a result signal when it completes. That fix is made *easier* by the protocol unification: no new `handle_info` clauses, no ref tracking — the runtime simply routes the result signal.

### Contract

Each directive declares its latency profile by how it returns:

- `{:ok, state}` after **bounded** work → the agent moves on immediately.
- `{:ok, state_with_loading_marker}` after spawning a task → the agent stays responsive; the task emits a completion **signal** that `cmd/2` will settle into `:success` or `:error`.
- `{:stop, reason, state}` → abnormal termination only (framework-level or irrecoverable errors).

Any directive doing slow *synchronous* work (blocking the GenServer without spawning) is a bug in that directive — inline signal processing makes this violation more visible, not less, because there's no drain yield to paper over a slow step.

## Consequences

### Semantic improvements

- **Multi-directive atomicity.** If signal A emits `[D1, D2, D3]` all returning `{:ok, state}` and signal B arrives mid-processing, B's `cmd/2` now observes state reflecting **all three** of A's synchronous updates, not a partial prefix. With the old drain loop, B could run between D1 and D2 and see only D1's effects. The new ordering is strictly stronger than the old one.

- **One correlation channel.** Async completions ride the signal bus. No bespoke `{:instruction_result, ref, …}` messages, no ref registries, no distinction between "primary signal inputs" and "async completions" at the runtime layer.

### Breaking / observability losses

- **`state.queue`, `state.signal_call_queue`, `state.deferred_async_signals` are gone.** Anything introspecting them externally breaks. Practically nothing did, but the fields are removed from the struct.
- **`status: :processing` is never observed.** A handler either returns inside a synchronous burst or it doesn't run — from outside, the agent is always `:initializing | :idle | :stopping`. `State.set_status/2`'s allowed values shrink accordingly.
- **`max_queue_size` / `[:jido, :agent_server, :queue, :overflow]` are gone.** Overflow is no longer a concept; backpressure comes from the Erlang mailbox. Callers that need it can use `Process.info(pid, :message_queue_len)`. The option is removed from `Jido.AgentServer.Options`.
- **`DirectiveExec.exec/3` return shape changed.** Any out-of-repo directive impls returning `{:async, ref, state}` must switch to `{:ok, state}`. Migration is mechanical: drop the `ref`, keep the `state`.
- **Signal-call exceptions still don't crash the agent.** The sync path's try/catch wraps `process_signal_sync/2` (replacing the Task's catch block), so exceptions in `cmd/2` become `{:error, reason}` replies. Async-path (`handle_cast` / `handle_info`) exceptions re-raise to crash the agent, as before.

### Diagnostics

`await_completion/2` timeout diagnostics replace `queue_length` with `mailbox_length` — the only meaningful "how much work is queued" metric under the new model.

### What hasn't changed

- Public `Signal.Call.call/3` API and correlation-id reply matching — unchanged; only the internal processing strategy changes.
- Telemetry event names: `[:jido, :agent_server, :signal, :start | :stop]`, `[:jido, :agent_server, :directive, :start | :stop]`, `[:jido, :agent_server, :signal, :exception]`. The `result: :async` metadata value is gone; the `:queue, :overflow` event is gone.
- Plugin signal hooks and transform hooks — same call sites, same contracts.
- Scheduled signals, cron jobs, lifecycle/InstanceManager integration, hierarchy — all unchanged.

## Alternatives considered

- **Keep the Task offload but drop the three queues.** Rejected: the Task offload wasn't protecting anything that needed protection, and keeping it would still require `signal_call_queue` + `deferred_async_signals` to serialize around the in-flight Task.

- **Keep `{:async, ref, state}` as an opaque marker.** Rejected: it created a parallel coordination path (ref-keyed mailbox messages) alongside signals. Collapsing to one channel is simpler, and every built-in directive already fits the signal-based pattern.

- **Ship `Jido.Agent.Async.start/settle` helpers as part of this ADR.** Deferred. The primitives exist (spawn + emit signal + `cmd/2` settles a loading marker) and follow-up work can package them into an ergonomic API once `RunInstruction` is refactored. The inline refactor doesn't depend on it.

## Follow-ups

- **Fix `RunInstruction` to use the spawn-task-emit-signal pattern.** The current impl still runs `Jido.Exec.run/1` synchronously inside the GenServer — the realistic blocking case in an agentic system. Fixing it is independently valuable and doesn't interact with this ADR except that the async version will write a loading marker and emit a settlement signal, fitting cleanly into the unified protocol.
- **Ship `Jido.Agent.Async.start/settle`** as a thin wrapper over the state-path-keyed loading-marker convention (RTK-Query-style `:loading | :success | :error`). Domain-path auto-prepending of `:__domain__` (per ADR 0008) keeps call sites concise.
- **Audit borderline sync directives** (`AdoptChild`, `SpawnAgent`, `StopChild`, `Reply`) against the fast-or-async contract; convert any that can block under adversarial conditions to the spawn-task-emit-signal pattern.
