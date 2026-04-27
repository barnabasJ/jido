# Directives

<!-- covers: jido.signals_and_directives.directive_effect_boundary jido.signals_and_directives.scheduling_support -->

**After:** You can emit directives from actions to perform effects without polluting pure logic.

Directives are **pure descriptions of external effects**. Agents emit them from `cmd/2` callbacks; the runtime (`AgentServer`) executes them.

## The Bright Line

- **Directives mutate no state.** Not domain (`agent.state`), not runtime (`%AgentServer.State{}`), nothing. They do I/O — emit signals, spawn processes, schedule messages, persist to disk — and return immediately.
- **Their results, if any, come back as signals that re-enter the pipeline.** Bookkeeping that logically follows the I/O — inserting a child into `state.children`, registering a cron spec, etc. — happens via the signal-cascade callbacks `process_signal/2` invokes (`maybe_track_child_started/2`, `handle_child_down/3`, `maybe_track_cron_registered/2`, …), **not** inside the directive's `exec/3` body.
- **The type system enforces it.** `Jido.AgentServer.DirectiveExec.exec/3` returns `:ok | {:stop, term()}` — there is no state slot, so a directive author cannot accidentally write one.
- **All `agent.state` writes flow through the action's return value.** That is the sole channel; sole exception is middleware `ctx.agent` staging for I/O purposes ([ADR 0018](adr/0018-tagged-tuple-return-shape.md) §1). The `RunInstruction` directive is no exception — after the strict tightening, its `result_signal_type` is dispatched through `signal_routes`, and the bound action returns the new slice the same way every other action does.

Canonical rule: [ADR 0019](adr/0019-actions-mutate-state-directives-do-side-effects.md).

## Directives vs Action Returns

Jido has exactly two channels for change, and they don't overlap:

| Concept | Where it lives | What it does |
|---------|----------------|--------------|
| **Action return value** | The slice value (or `%SliceUpdate{}`) returned from an action's `run/2` | Mutates `agent.state` — sole channel |
| **Directives** | `Jido.Agent.Directive.*` structs returned alongside the slice | Pure I/O — emit signals, spawn processes, schedule messages. Mutate nothing. |

Reading the action tells you everything that changes in `agent.state`. Reading the directive list tells you everything the runtime will do as I/O. The two lists do not overlap.

```elixir
def cmd({:notify_user, message}, agent, _context) do
  signal = Jido.Signal.new!("notification.sent", %{message: message}, source: "/agent")

  {:ok, agent, [Directive.emit(signal)]}
end
```

## Core Directives

| Directive | Purpose | Tracking |
|-----------|---------|----------|
| `Emit` | Dispatch a signal via configured adapters | — |
| `Error` | Signal an error from cmd/2 | — |
| `Spawn` | Spawn generic BEAM child process | None (fire-and-forget) |
| `SpawnAgent` | Spawn child Jido agent with hierarchy | Full (monitoring, exit signals, `restart: :transient` default) |
| `AdoptChild` | Attach an orphaned or unattached child to the current parent | Full (monitoring, parent ref refresh, children map update) |
| `StopChild` | Gracefully stop and remove a tracked child agent | Uses children map |
| `Schedule` | Schedule a delayed message | — |
| `RunInstruction` | Execute `%Instruction{}` at runtime and route result back through `cmd/2` | — |
| `Stop` | Stop the agent process (self) | — |
| `Cron` | Recurring scheduled execution | — |
| `CronCancel` | Cancel a cron job | — |

## Helper Constructors

```elixir
alias Jido.Agent.Directive

# Emit signals
Directive.emit(signal)
Directive.emit(signal, {:pubsub, topic: "events"})
Directive.emit_to_pid(signal, pid)
Directive.emit_to_parent(agent, signal)

# Spawn processes
Directive.spawn(child_spec)
Directive.spawn_agent(MyWorkerAgent, :worker_1)
Directive.spawn_agent(MyWorkerAgent, :processor, opts: %{initial_state: %{batch_size: 100}})
Directive.spawn_agent(MyWorkerAgent, :durable, restart: :permanent)
Directive.adopt_child("worker-123", :recovered_worker)
Directive.adopt_child(child_pid, :recovered_worker, meta: %{restored: true})

# Stop processes
Directive.stop_child(:worker_1)
Directive.stop()
Directive.stop(:shutdown)

# Scheduling
Directive.schedule(5000, :timeout)
Directive.cron("*/5 * * * *", :tick, job_id: :heartbeat)
Directive.cron_cancel(:heartbeat)

# Runtime instruction execution
Directive.run_instruction(instruction, result_action: :fsm_instruction_result)

# Errors
Directive.error(Jido.Error.validation_error("Invalid input"))
```

## Cron and CronCancel Semantics

`Cron` and `CronCancel` are failure-isolated:

- Invalid cron expression or timezone is rejected at runtime without crashing the agent
- Scheduler registration failures return errors and leave agent state unchanged
- `CronCancel` is safe when runtime pid is missing; durable spec removal still applies

For keyed InstanceManager lifecycles with storage enabled, dynamic cron mutations are
write-through durable via `Jido.Persist`/`Jido.Storage` before state commit.
Non-persistent lifecycles keep cron state runtime-only.

## RunInstruction

`RunInstruction` is used by strategies that keep `cmd/2` pure. Instead of calling
`Jido.Exec.run/1` inline, the strategy emits `%Directive.RunInstruction{}` and the
runtime executes it, then routes the result back through `cmd/2` using `result_action`.

## Spawn vs SpawnAgent

| `Spawn` | `SpawnAgent` |
|---------|--------------|
| Generic Tasks/GenServers | Child Jido agents |
| Fire-and-forget | Full hierarchy tracking |
| No monitoring | Monitors child, receives exit signals |
| — | Enables `emit_to_parent/3` |

```elixir
# Fire-and-forget task
Directive.spawn({Task, :start_link, [fn -> send_webhook(url) end]})

# Tracked child agent
Directive.spawn_agent(WorkerAgent, :worker_1, opts: %{initial_state: state})
```

`SpawnAgent` forwards standard child startup options such as `:id`,
`:initial_state`, and `:on_parent_death`. It does not install
`InstanceManager` lifecycle features, so lifecycle/persistence options like
`:storage`, `:idle_timeout`, `:lifecycle_mod`, `:pool`, `:pool_key`, and
`:restored_from_storage` are rejected.

`SpawnAgent` children default to `restart: :transient`, which means:
- `Directive.stop_child/2` cleanly removes them
- abnormal exits still restart the child
- callers can override to `:permanent` or `:temporary` when needed

Children spawned this way can later become orphaned if `on_parent_death` is set
to `:continue` or `:emit_orphan`. In that case, `Directive.adopt_child/3` is
the explicit way to reattach the live child to a new logical parent. Jido keeps
the active logical binding in `Jido.RuntimeStore`, so child restarts continue
to use the current parent relationship after adoption.

## Parent-Aware Communication

`Directive.emit_to_parent/3` is intentionally strict:

- it works only while `agent.state.__parent__` is present
- it returns `nil` for standalone agents
- it returns `nil` for orphaned agents after the runtime clears `__parent__`

That prevents stale routing to a dead coordinator. If a child needs to remember
where it came from after orphaning, read `agent.state.__orphaned_from__` or
handle `jido.agent.orphaned` instead of relying on `emit_to_parent/3`.

See [Orphans & Adoption](orphans.md) for the full orphan lifecycle.

## Custom Directives

External packages can define their own directives:

```elixir
defmodule MyApp.Directive.CallLLM do
  defstruct [:model, :prompt, :tag]
end
```

The runtime dispatches on struct type — no core changes needed. Implement a custom `AgentServer` or middleware to handle your directive types.

## Complete Example: Action → Directive Flow

Here's a full example showing an action that processes an order and emits a signal:

```elixir
defmodule ProcessOrderAction do
  use Jido.Action,
    name: "process_order",
    schema: [order_id: [type: :string, required: true]]

  alias Jido.Agent.Directive

  def run(%{order_id: order_id}, context) do
    signal = Jido.Signal.new!(
      "order.processed",
      %{order_id: order_id, processed_at: DateTime.utc_now()},
      source: "/orders"
    )

    new_slice = Map.put(context.state, :last_order, order_id)

    {:ok, new_slice, [Directive.emit(signal)]}
  end
end
```

When the agent runs this action via `cmd/2`:
1. The framework writes the returned slice value into `agent.state` at the action's declared `path:` — this is the **sole** channel for state changes.
2. The `Emit` directive passes through to the runtime as pure I/O.
3. `AgentServer` dispatches the signal via configured adapters.

---

See `Jido.Agent.Directive` moduledoc for the complete API reference.

**Related guides:** [Orphans & Adoption](orphans.md), [ADR 0019](adr/0019-actions-mutate-state-directives-do-side-effects.md)
