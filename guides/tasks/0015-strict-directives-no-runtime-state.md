# Task 0015 — Strict directives: no runtime-state mutation; tighten `DirectiveExec` contract

- Implements: [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) — the cross-cutting tightening of the agent-side directive surface so the principle "directives are pure I/O" holds uniformly across the codebase, not just on the Pod surface that [task 0010](0010-pod-runtime-signal-driven-state-machine.md) cleaned up.
- Depends on: [task 0010](0010-pod-runtime-signal-driven-state-machine.md) (the Pod state machine is the worked example this task generalises; the synthesize-then-cascade pattern lands there first).
- Blocks: nothing in the 0014–0021 chain — this is the terminal cleanup that closes the gap ADR 0019 left open.
- Leaves tree: **green**

## Goal

Make ADR 0019 §1's strict reading enforceable by the type system across the whole `lib/jido/agent/directive*` surface:

> Directives are pure side effects. They mutate NO state — not domain (`agent.state`), not runtime (`state.children`, `state.cron_*`, monitors, subscriptions).

Two halves to this task; **Step 0 lands first** so the rest is type-system-enforced.

### Step 0 — Tighten the `DirectiveExec` contract (per ADR 0019 §6)

Drop state from the protocol's return shape:

```elixir
# Before
@spec exec(directive, signal, state) :: {:ok, state} | {:stop, term(), state}

# After
@spec exec(directive, signal, state) :: :ok | {:stop, term()}
```

State stays as **input** (directives still read fields). It just stops being part of the return — there's no longer a slot for a mutated state to land in. Reviewers don't have to verify the returned state is byte-equal to the input; the compiler already did.

`execute_directives/3` in `lib/jido/agent_server.ex` threads the original state through unchanged. `Stop` directive's `{:stop, reason, state}` collapses to `{:stop, reason}` — `execute_directives/3` adds state back when propagating to the GenServer.

No `{:error, _}` return: directives that fail internally log and return `:ok` (the existing `Error` directive's swallow-and-continue convention). Anything that should abort the batch escalates via `{:stop, reason}`. `execute_directives/3` doesn't need a third decision between log-and-continue vs. abort — there's no caller asking for it.

Every existing `defimpl Jido.AgentServer.DirectiveExec` block updates: `{:ok, state}` → `:ok`, `{:stop, reason, state}` → `{:stop, reason}`. About 13 impls across the agent and pod surfaces. Mechanical change.

### Step 1 — Split the five violators

After Step 0 the type system rejects state mutation, but the existing five violators don't compile (they return `{:ok, mutated_state}`). Fix them by splitting into "pure I/O directive" + "cascade callback (or routed action) that observes the resulting signal and updates state":

1. **`Jido.Agent.Directive.SpawnAgent`** — adds the spawned child to `state.children` directly.
2. **`Jido.Agent.Directive.AdoptChild`** — adds the adopted child to `state.children` directly.
3. **`Jido.Agent.Directive.Cron`** — registers a job and inserts the spec / pid / monitors into the runtime maps directly.
4. **`Jido.Agent.Directive.CronCancel`** — removes the spec / pid from the runtime maps directly.
5. **`Jido.Agent.Directive.RunInstruction`** — runs an instruction and calls `state.agent_module.cmd/2`, mutating `state.agent` (DOMAIN). This is the worst offender.

The only legal channels for runtime-state mutation are AgentServer GenServer callbacks (`handle_call`/`handle_cast`/`handle_info`) and the cascade callbacks `process_signal/2` already invokes (`maybe_track_child_started/2`, `handle_child_down/3`, plus the new `maybe_track_cron_*` family this task introduces).

## Files to modify

### Step 0 — Tighten the `DirectiveExec` contract

#### `lib/jido/agent_server/directive_exec.ex`

Update the protocol's `@spec` and supporting docs:

```elixir
defprotocol Jido.AgentServer.DirectiveExec do
  @moduledoc """
  ...

  ## Return Values

  - `:ok` — directive executed successfully, continue processing
  - `{:stop, reason}` — **hard stop** the agent process

  Directives never return state. State is passed in as the third arg
  (for reading); mutating it is impossible by the type signature, per
  ADR 0019 §6. Bookkeeping that logically follows the I/O happens via
  the cascade callbacks `process_signal/2` invokes
  (`maybe_track_child_started/2`, `handle_child_down/3`,
  `maybe_track_cron_registered/2`, `maybe_track_cron_cancelled/2`).

  Failure handling: directives that hit an internal error log it and
  return `:ok` — same swallow-and-continue convention the `Error`
  directive already follows. There's no `{:error, _}` return because
  `execute_directives/3` would have nowhere meaningful to send it; if
  the failure should abort the batch and stop the agent, escalate via
  `{:stop, reason}`.
  ...
  """

  @spec exec(struct(), Jido.Signal.t(), Jido.AgentServer.State.t()) ::
          :ok | {:stop, term()}
  def exec(directive, input_signal, state)
end
```

Rewrite the moduledoc's "async pattern" example. The current example
sets a loading marker on agent state from inside the directive — that's
exactly the violation this task forbids. Replace with the
synthesize-then-action pattern: the directive spawns the task; the
completion signal routes to an action that sets the loading marker via
its return value.

#### `lib/jido/agent_server.ex`

Rewrite `execute_directives/3` to thread state through unchanged:

```elixir
@spec execute_directives([struct()], Signal.t(), State.t()) ::
        {:ok, State.t()} | {:stop, term(), State.t()}
def execute_directives([], _signal, state), do: {:ok, state}

def execute_directives([directive | rest], signal, state) do
  TraceContext.set_from_signal(signal)

  result =
    try do
      exec_directive_with_telemetry(directive, signal, state)
    after
      TraceContext.clear()
    end

  case result do
    :ok ->
      execute_directives(rest, signal, state)

    {:stop, reason} ->
      warn_if_normal_stop(reason, directive, state)
      {:stop, reason, state}
  end
end
```

Notice `execute_directives/3` adds `state` back when propagating
`{:stop, reason, state}` to the GenServer — the directive's return is
just `{:stop, reason}`, and `execute_directives/3` is the only caller
that knows the current state.

#### Update every `defimpl Jido.AgentServer.DirectiveExec` block

Mechanical sweep across:

- `lib/jido/agent_server/directive_executors.ex` — `Emit`, `Error`,
  `RunInstruction`, `Spawn`, `Schedule`, `SpawnAgent`, `AdoptChild`,
  `StopChild`, `Stop`, `SpawnManagedAgent`, `Reply`, `Any`
- `lib/jido/agent/directive/cron.ex` — `Cron`
- `lib/jido/agent/directive/cron_cancel.ex` — `CronCancel`
- `lib/jido/pod/directive_exec.ex` — `StartNode`, `StopNode`

Two transforms:

| Before | After |
|---|---|
| `{:ok, state}` | `:ok` |
| `{:stop, reason, state}` | `{:stop, reason}` |

For directives that already return state unchanged
(`Emit`, `Error`, `Spawn`, `Schedule`, `SpawnManagedAgent`, `Reply`,
`StopChild`, `StartNode`, `StopNode`, the `Any` fallback), the change
is just deleting `state` from the return.

For `Stop`, the directive returns `{:stop, reason}` —
`execute_directives/3` will rewrap to `{:stop, reason, state}` for the
GenServer.

For the violators (Step 1 work), the new shape is `:ok` after the
state-mutation lines are removed. Step 0 lands first, the violators
fail to compile (`{:ok, %{state | children: ...}}` is no longer a
valid return), Step 1 fixes them.

#### `lib/jido/agent_server/stop_child_runtime.ex`

`StopChildRuntime.exec/4` is called from two places:
- `defimpl ... for: Jido.Agent.Directive.StopChild` (directive context — must follow new contract)
- `handle_call({:stop_child, tag, reason}, ...)` (GenServer callback — keeps old shape)

Refactor: `StopChildRuntime.exec_io/4` does the I/O and returns
`:ok | {:error, reason}`; the directive uses that. The
`handle_call({:stop_child, ...})` callback wraps it for backward
compatibility with the call's return.

(Cleaner: `handle_call` is allowed to mutate state, so it can keep
calling the existing `exec/4` shape if that helper retains state in
the return. Just route the directive through a different entry
point. Pick whichever is less invasive.)

### Step 1 — Split the five violators

#### `Jido.Agent.Directive.SpawnAgent` impl

The directive's exec currently:

```elixir
case DynamicSupervisor.start_child(supervisor, child_spec) do
  {:ok, pid} ->
    case persist_relationship(state, child_id, child_partition, tag, meta) do
      :ok ->
        ref = Process.monitor(pid)
        child_info = ChildInfo.new!(%{...})
        new_state = State.add_child(state, tag, child_info)
        {:ok, new_state}
```

The `Process.monitor` and `State.add_child` are the violations — they're already done by `maybe_track_child_started/2` when the child boots and casts `jido.agent.child.started`. The directive's bookkeeping is duplicate work; remove it:

```elixir
case DynamicSupervisor.start_child(supervisor, child_spec) do
  {:ok, pid} ->
    case persist_relationship(state, child_id, child_partition, tag, meta) do
      :ok ->
        Logger.debug("AgentServer #{state.id} spawned child #{child_id} with tag #{inspect(tag)}")
        {:ok, state}

      {:error, reason} ->
        _ = DynamicSupervisor.terminate_child(supervisor, pid)
        Logger.error("...")
        {:ok, state}
    end
```

`persist_relationship` writes to the external `RuntimeStore` — that's I/O, allowed.

The natural `child.started` (from the spawned child's `notify_parent_of_startup`) arrives in the parent's mailbox shortly after. `process_signal/2` calls `maybe_track_child_started/2`, which inserts the `%ChildInfo{}` and creates the monitor. State.children is consistent without the directive touching it.

**Race note**: between `start_child` returning `{:ok, pid}` and the natural `child.started` arriving, the parent doesn't yet have the child in `state.children`. Code that does `State.get_child(state, tag)` between those points will return `nil`. This window is microseconds-to-milliseconds in practice; the only consumers are tests using `await_child/3` (which subscribes to `jido.agent.child.started` already, so race-free) and user code that should also be subscribing. Document the window in the directive's moduledoc.

#### `Jido.Agent.Directive.AdoptChild` impl

The directive's exec currently:

```elixir
def exec(%{child: child, tag: tag, meta: meta}, _input_signal, state) do
  with :ok <- ensure_tag_available(state, tag),
       {:ok, child_pid} <- resolve_child(child, state),
       :ok <- ensure_not_self(child_pid),
       {:ok, child_runtime} <- adopt_child(child_pid, tag, meta, state) do
    child_info = ChildInfo.new!(%{...})
    {:ok, State.add_child(state, tag, child_info)}
```

`adopt_child/4` calls `AgentServer.adopt_parent(child_pid, parent_ref)` on the child. That's the I/O. Inside `handle_call({:adopt_parent, ...})` on the *child* side, the child calls `notify_parent_of_startup(new_state)` which casts `jido.agent.child.started` back to the new parent (us). So the natural cascade fires — we don't need to call `State.add_child/3` ourselves.

Strip it:

```elixir
def exec(%{child: child, tag: tag, meta: meta}, _input_signal, state) do
  with :ok <- ensure_tag_available(state, tag),
       {:ok, child_pid} <- resolve_child(child, state),
       :ok <- ensure_not_self(child_pid),
       {:ok, _child_runtime} <- adopt_child(child_pid, tag, meta, state) do
    Logger.debug("AgentServer #{state.id} initiated adoption of child with tag #{inspect(tag)}")
    {:ok, state}
  else
    {:error, reason} ->
      Logger.warning("...")
      {:ok, state}
  end
end
```

The `handle_call({:adopt_child, ...})` path in `agent_server.ex` (the imperative API, not the directive) is the canonical case where state mutation is allowed — it's a GenServer callback. It can keep its `State.add_child/3` call. The directive defers to the natural cascade.

**Note on `handle_call({:adopt_child, ...})`**: it currently does both `State.add_child` AND dispatches a synthetic `child.adopted` signal. Leave it as-is — that's the GenServer-callback channel allowed by ADR 0019 §5. The duplicated state.children write that the cascade would later perform on the natural `child.started` is idempotent (`maybe_track_child_started/2` sees the same pid + tag and returns state unchanged).

#### `Jido.Agent.Directive.Cron` impl

The directive currently calls `Jido.Agent.Directive.Cron.register/6` which:
1. Builds a cron spec (pure).
2. Calls `AgentServer.start_runtime_cron_job(state, logical_id, runtime_spec)` — spawns the scheduler job (I/O).
3. Calls `persist_then_commit_registration` — persists to disk (I/O) **and** mutates `state.cron_specs`, `state.cron_jobs`, `state.cron_monitors`, etc.

Step 3 is the violation — the runtime-map updates happen inside the directive body. Split into:

- **Directive side (pure I/O)**: build spec, start the scheduler job, persist to disk, synthesize a `jido.agent.cron.registered` signal cast to `self()` carrying `{logical_id, pid, monitor_ref, cron_spec, runtime_spec}`. Return `{:ok, state}` with no field write.
- **Cascade side (`maybe_track_cron_registered/2` in `agent_server.ex`)**: pattern-matches `jido.agent.cron.registered` in `process_signal/2` (alongside `maybe_track_child_started/2`); on match, inserts into `state.cron_specs` / `state.cron_jobs` / `state.cron_monitors` / `state.cron_monitor_refs` / `state.cron_runtime_specs` from the signal's data.

```elixir
# lib/jido/agent_server.ex

defp process_signal(%State{} = state, %Signal{} = signal) do
  ...
  state =
    state
    |> State.record_debug_event(:signal_received, %{type: signal.type, id: signal.id})
    |> maybe_track_child_started(signal)
    |> maybe_track_cron_registered(signal)     # NEW
    |> maybe_track_cron_cancelled(signal)      # NEW
  ...
end

defp maybe_track_cron_registered(
       %State{} = state,
       %Signal{type: "jido.agent.cron.registered", data: data}
     ) when is_map(data) do
  with %{
         job_id: job_id,
         pid: pid,
         monitor_ref: monitor_ref,
         cron_spec: cron_spec,
         runtime_spec: runtime_spec
       } <- data do
    %{state |
      cron_specs: Map.put(state.cron_specs, job_id, cron_spec),
      cron_runtime_specs: Map.put(state.cron_runtime_specs, job_id, runtime_spec),
      cron_jobs: Map.put(state.cron_jobs, job_id, pid),
      cron_monitors: Map.put(state.cron_monitors, job_id, monitor_ref),
      cron_monitor_refs: Map.put(state.cron_monitor_refs, monitor_ref, job_id)
    }
  else
    _ -> state
  end
end

defp maybe_track_cron_registered(state, _signal), do: state
```

The directive impl becomes a thin wrapper that does the I/O and casts the synthetic signal:

```elixir
defimpl Jido.AgentServer.DirectiveExec, for: Jido.Agent.Directive.Cron do
  def exec(%{cron: cron_expr, message: message, job_id: logical_id, timezone: tz}, _input_signal, state) do
    logical_id = logical_id || make_ref()

    with {:ok, cron_spec} <- Jido.Scheduler.validate_and_build_cron_spec(cron_expr, message, tz),
         runtime_spec <- CronRuntimeSpec.dynamic(...),
         {:ok, pid} <- Jido.AgentServer.start_runtime_cron_job(state, logical_id, runtime_spec),
         :ok <- Jido.AgentServer.persist_cron_specs(state, Map.put(state.cron_specs, logical_id, cron_spec)) do
      monitor_ref = Process.monitor(pid)

      synthetic =
        Jido.Signal.new!(
          "jido.agent.cron.registered",
          %{
            job_id: logical_id,
            pid: pid,
            monitor_ref: monitor_ref,
            cron_spec: cron_spec,
            runtime_spec: runtime_spec
          },
          source: "/agent/#{state.id}"
        )

      _ = Jido.AgentServer.cast(self(), synthetic)
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("AgentServer #{state.id} failed to register cron job #{inspect(logical_id)}: #{inspect(reason)}")
        {:ok, state}
    end
  end
end
```

**Note on `Process.monitor`**: monitoring is technically a runtime-state effect (the BEAM tracks the monitor reference), but it's an OS-level resource, not a `%State{}` field write. It belongs in the I/O directive — same category as `Process.exit/2`, `cast/2`, etc. The `monitor_ref` it returns is data passed via the synthetic signal to the cascade callback, which records it into `state.cron_monitor_refs`.

#### `Jido.Agent.Directive.CronCancel` impl

Mirror split. Directive does the I/O (cancel via `Jido.AgentServer.untrack_cron_job(state, logical_id, ...)`, persist the new spec map). Then synthesizes `jido.agent.cron.cancelled` carrying `{job_id, pid, monitor_ref}`. The cascade callback `maybe_track_cron_cancelled/2` removes from the runtime maps.

The wrinkle: `Jido.AgentServer.untrack_cron_job/3` returns the new state with maps cleared. We need to factor out a "look up the job's pid + monitor_ref without mutating state" helper, then have the cascade callback do the actual map cleanup.

```elixir
defimpl Jido.AgentServer.DirectiveExec, for: Jido.Agent.Directive.CronCancel do
  def exec(%{job_id: logical_id}, _input_signal, state) do
    pid = Map.get(state.cron_jobs, logical_id)
    monitor_ref = Map.get(state.cron_monitors, logical_id)
    proposed_specs = Map.delete(state.cron_specs, logical_id)

    if is_pid(pid) do
      # I/O: cancel the scheduler job + demonitor + persist
      _ = Jido.Scheduler.cancel(pid, logical_id)
      if is_reference(monitor_ref), do: Process.demonitor(monitor_ref, [:flush])
    end

    _ = Jido.AgentServer.persist_cron_specs(state, proposed_specs)

    synthetic =
      Jido.Signal.new!(
        "jido.agent.cron.cancelled",
        %{job_id: logical_id, pid: pid, monitor_ref: monitor_ref},
        source: "/agent/#{state.id}"
      )

    _ = Jido.AgentServer.cast(self(), synthetic)
    {:ok, state}
  end
end
```

And the cascade:

```elixir
defp maybe_track_cron_cancelled(
       %State{} = state,
       %Signal{type: "jido.agent.cron.cancelled", data: %{job_id: job_id, monitor_ref: monitor_ref}}
     ) do
  %{state |
    cron_specs: Map.delete(state.cron_specs, job_id),
    cron_runtime_specs: Map.delete(state.cron_runtime_specs, job_id),
    cron_jobs: Map.delete(state.cron_jobs, job_id),
    cron_monitors: Map.delete(state.cron_monitors, job_id),
    cron_monitor_refs: if(is_reference(monitor_ref), do: Map.delete(state.cron_monitor_refs, monitor_ref), else: state.cron_monitor_refs)
  }
end

defp maybe_track_cron_cancelled(state, _signal), do: state
```

**Note**: `Jido.AgentServer.untrack_cron_job/3` (the public helper) currently both does the I/O (cancel) and the state mutation in one call. After this task, callers split into:
- I/O part stays in `untrack_cron_job/3` (or a renamed helper like `cancel_cron_job_io/2`).
- State-mutation part moves into the cascade callback.

Audit `untrack_cron_job/3`'s callers (in particular `handle_info` for cron `:DOWN` signals) — those callers ARE GenServer callbacks, so they're allowed to mutate state directly. They can keep doing both halves; only the directive path needs the split.

#### `Jido.Agent.Directive.RunInstruction` impl

This is the worst case — the directive body mutates `state.agent` (DOMAIN state). Today:

```elixir
def exec(%{instruction: instruction, result_action: result_action, meta: meta}, input_signal, state) do
  enriched_instruction = %{instruction | context: Map.put(instruction.context || %{}, :state, state.agent.state)}

  execution_payload =
    enriched_instruction
    |> then(fn instruction -> Jido.Exec.run(...) end)
    |> normalize_result_payload()
    |> Map.put(:instruction, instruction)
    |> Map.put(:meta, meta || %{})

  case state.agent_module.cmd(state.agent, {result_action, execution_payload}, ...) do
    {:ok, agent, directives} ->
      state = State.update_agent(state, agent)
      AgentServer.execute_directives(List.wrap(directives), input_signal, state)
    {:error, reason} ->
      ...
  end
end
```

Split:

- **Directive side (pure I/O)**: run the instruction, build the execution_payload, **emit a result signal** (the `result_action` was originally the action module to invoke; that becomes a signal type). Return `{:ok, state}`.
- **Action side (routed to the result signal type via `signal_routes`)**: the user's existing `result_action` module already implements `run/4`. It just needs to be wired as a route handler instead of being invoked via `cmd/2` from inside the directive. The framework's normal slice-update path then commits the result.

The `result_action` field of the directive currently doubles as both "module to invoke" and "what receives the payload." After the split:

```elixir
%RunInstruction{
  instruction: instruction,
  result_action: MyApp.HandleAsyncResult,   # action module — must declare a path:
  result_signal_type: "myapp.async.result",  # NEW: the signal type the directive emits
  meta: meta
}
```

The directive emits `Signal.new!(result_signal_type, execution_payload, source: "/agent/#{state.id}")`. The agent's `signal_routes` need a route for `result_signal_type` to `result_action`. Both fields are required so the directive can fire the signal AND the existing route table is the dispatch mechanism.

```elixir
defimpl Jido.AgentServer.DirectiveExec, for: Jido.Agent.Directive.RunInstruction do
  def exec(
        %{instruction: instruction, result_signal_type: signal_type, meta: meta},
        _input_signal,
        state
      ) do
    enriched_instruction = %{instruction | context: Map.put(instruction.context || %{}, :state, state.agent.state)}

    execution_payload =
      enriched_instruction
      |> then(fn instruction ->
        exec_opts = ObserveConfig.action_exec_opts(state.jido, instruction.opts)
        Jido.Exec.run(%{instruction | opts: exec_opts})
      end)
      |> normalize_result_payload()
      |> Map.put(:instruction, instruction)
      |> Map.put(:meta, meta || %{})

    result_signal =
      Jido.Signal.new!(signal_type, execution_payload, source: "/agent/#{state.id}")

    _ = Jido.AgentServer.cast(self(), result_signal)
    {:ok, state}
  end
end
```

**Migration cost**: every call site of `Directive.run_instruction(...)` needs to add a `result_signal_type:` and the agent declaring that directive needs a corresponding `signal_routes` entry. Search the codebase for `RunInstruction.new` or `run_instruction(` and update each. The two `result_action: nil` cases (where the caller didn't want a follow-up) become "no signal_routes entry, signal is unrouted, no-op." Mark those callsites for inspection — they may have been silently dropping the result.

### `lib/jido/agent_server.ex`

**Add the cascade callbacks** to `process_signal/2`'s pre-chain pipeline:

```elixir
state =
  state
  |> State.record_debug_event(:signal_received, %{type: signal.type, id: signal.id})
  |> maybe_track_child_started(signal)
  |> maybe_track_cron_registered(signal)
  |> maybe_track_cron_cancelled(signal)
```

Both callbacks live in the same `Internal: signal-driven runtime tracking` block as `maybe_track_child_started/2`.

**Audit `start_runtime_cron_job/3`, `persist_cron_specs/2`, `untrack_cron_job/3`, `emit_cron_telemetry_event/3`** — these are the helpers the Cron directive calls into. After the split:

- `start_runtime_cron_job/3` should remain "spawn the scheduler job + return the pid" without state mutation.
- `persist_cron_specs/2` already returns `:ok | {:error, _}` — keep as-is.
- `untrack_cron_job/3` callers split: GenServer callbacks (e.g., the cron `:DOWN` `handle_info`) can keep the combined "cancel + mutate state" version; the directive path uses only the cancel-side half.

Refactor as needed to expose the I/O-only halves cleanly.

### `lib/jido/agent/directive.ex`

**Update `RunInstruction` schema** to add `result_signal_type` (required) and remove the implicit "result_action is the dispatch target" coupling:

```elixir
%RunInstruction{
  instruction: ...,
  result_signal_type: "myapp.async.result",
  meta: ...
}
```

The `result_action` field can be retired or repurposed (e.g., kept only for documentation / introspection; the actual dispatch is via `signal_routes`).

Document the new shape in the `RunInstruction` moduledoc with a usage example.

### `lib/jido/agent/directive/cron.ex`

The `Jido.Agent.Directive.Cron.register/6` helper currently does I/O **and** state mutation. After the split, callers (the directive's exec impl, plus any in-tree callers like `register_restored_cron_specs/1`) need to use the I/O-only half. Three options:

1. **Split `register/6` into two functions**: `register_io/6` (returns `{:ok, %{logical_id: _, pid: _, monitor_ref: _, cron_spec: _, runtime_spec: _}}` without mutation) and `commit_register/2` (does the state mutation). The directive uses `register_io/6` + synthesize signal; non-directive callers (GenServer callbacks) use `register_io/6` + `commit_register/2` directly.
2. **Keep `register/6` for callbacks** (it's allowed to mutate state — it's called from a GenServer context); add `register_io/6` as the directive-safe variant.
3. **Inline** everything into the directive's exec (don't share with callbacks).

Option 1 is the cleanest. Do that.

`register_restored_cron_specs/1` (called from `handle_continue(:post_init, state)`) is a GenServer callback — keep it calling the old `register/6` shape (or the new combined helper). It's allowed to mutate state directly.

## Files to create

None. The cascade callbacks are added inline in `agent_server.ex`. The synthesized signal types (`jido.agent.cron.registered`, `jido.agent.cron.cancelled`) reuse `Jido.Signal.new!/3` — they don't need dedicated `use Jido.Signal` modules unless we want them in `lib/jido/agent_server/signal/`. Defer the schema modules until a downstream consumer actually needs them.

## Files to delete

None.

## Tests

### `test/jido/agent/directive_executors_test.exs` (or wherever directive impls are tested)

For each fixed directive, add a strict-separation test analogous to the one [task 0010](0010-pod-runtime-signal-driven-state-machine.md) added for `StartNode`:

- Capture `state` (specifically `state.children` / `state.cron_*` / `state.agent`) before applying the directive.
- Apply the directive via `Jido.AgentServer.DirectiveExec.exec/3` inside the agent process (via a `state/3` selector).
- Capture after.
- Assert the relevant runtime-field maps / domain slice are byte-equal to the input.
- Separately, assert that the natural cascade (which fires asynchronously) eventually populates the field — using `JidoTest.AgentWait.await_state_value/3` subscribed to the appropriate lifecycle signal.

For `RunInstruction`: assert the directive returns state unchanged and emits a signal whose type matches `result_signal_type`. The downstream slice update happens via the routed action — test that separately at the agent level.

### `test/jido/agent_server_test.exs` (or wherever child / cron lifecycle is tested)

Existing tests that assert "after `SpawnAgent`, `state.children[tag]` is set immediately" need to be updated to wait via `await_child/3` or `await_state_value/3` — the natural cascade is now the only writer, and it runs asynchronously.

### Regression checks

The primary check is the type system itself: after Step 0 lands, the
`DirectiveExec.exec/3` return type is `:ok | {:stop, term()}`.
A directive that tries to return `{:ok, mutated_state}` fails to compile.
`mix compile --warnings-as-errors` is the regression check.

Belt-and-suspenders grep (catches state mutations inside the directive
body that don't escape via the return — e.g., a `State.add_child` call
whose result is discarded):

```bash
# Should return zero hits inside `defimpl ... for: Jido.Agent.Directive.*` blocks.
grep -rn 'State.add_child\|State.remove_child\|State.update_agent\|State\.\(add_\|remove_\|update_\)\|cron_specs:\|cron_jobs:\|cron_monitors:\|cron_monitor_refs:\|cron_runtime_specs:' \
  lib/jido/agent_server/directive_executors.ex \
  lib/jido/agent/directive/*.ex \
  lib/jido/pod/directive_exec.ex
```

The grep will hit `agent_server.ex` (where mutations are legal — GenServer
callbacks) and `state.ex` (the field defs) — those are out of scope; the
grep filters by file.

## Acceptance

- `mix compile --warnings-as-errors` clean — this *is* the strict-rule check after Step 0. The protocol's `@spec` is `:ok | {:stop, term()}`, so any directive returning `{:ok, state}` (mutated or not) fails dialyzer / compile.
- `mix test` — full suite passes.
- The Step-0 grep above (`State.add_child`, `cron_specs:`, etc.) returns zero hits inside directive impls. Belt-and-suspenders for state mutations whose result doesn't escape via return.
- The `DirectiveExec` protocol's `@spec exec(...)` reads `:ok | {:stop, term()}` (no state in any return shape).
- `Stop` directive returns `{:stop, reason}`; `execute_directives/3` rewraps to `{:stop, reason, state}` for the GenServer.
- Each fixed directive (Step 1) has a strict-separation test that asserts the natural cascade fires (via `await_state_value/3`) — the type system already proves the directive itself didn't mutate.

## Out of scope

- **`maybe_track_child_started/2` and `handle_child_down/3` themselves.** They already do exactly what we need; this task only adds the cron-side analogs and updates directives to defer to them. The child-side cascade is untouched.

- **The `handle_call({:adopt_child, ...})` GenServer callback.** It's allowed to mutate state directly per ADR 0019 §5. Keep it as-is. Only the `Jido.Agent.Directive.AdoptChild` directive impl changes.

- **Synthesizing signals for *every* lifecycle event.** This task only adds `jido.agent.cron.registered` and `jido.agent.cron.cancelled` because the cron path needs them. If a future directive lands that mutates `state.signal_subscribers`, `state.ready_waiters`, etc., a new cascade pair will be needed then — not pre-emptively.

- **Pod surface.** [task 0010](0010-pod-runtime-signal-driven-state-machine.md) already cleaned this up. `StartNode`, `StopNode`, `MutateProgress` already follow the strict rule; no changes here.

## Risks

- **The async window between directive return and cascade callback.** For `SpawnAgent` and `AdoptChild`, the directive returns and the test continues without `state.children[tag]` populated. Tests that assert immediate visibility will time out. Audit them; switch to `await_child/3`. This is a behavior-visible change — call it out in the task commit.

- **Cron `:DOWN` race.** Today the cron `handle_info({:DOWN, ref, :process, pid, reason})` handler reads `state.cron_monitor_refs` and `state.cron_jobs` to identify which job died. With the cascade pattern, those maps are populated by `maybe_track_cron_registered/2` only after the directive's synthetic signal is processed. If the cron job dies *before* the synthetic is processed, the `:DOWN` lands in mailbox before the signal — the handler sees empty maps and can't identify the job. Mitigation: in the synthesize-step, if the spawn already failed (process died synchronously), don't synthesize; surface the failure via the directive's return + a `cron.failed` signal that doesn't try to update tracking maps. The synthesize-on-success path is the only case the cascade runs.

- **`RunInstruction`'s `result_action` semantics change.** The implicit "module receives the payload via cmd/2" becomes explicit "signal type routes to module via signal_routes." This is a public API break for anyone using `RunInstruction` directly. Document migration; provide a one-shot codemod note in the task commit body.

- **Test rewrites.** The directive tests that asserted on `state.children[tag]` immediately after `SpawnAgent.exec/3` need updating. Budget 1-2 hours.

- **`Process.monitor` in directive bodies.** Conceptually a runtime-state effect (the BEAM tracks the ref), but practically OS-level. This task treats `Process.monitor`/`Process.demonitor` as I/O and allows them in directive bodies — the resulting `monitor_ref` is *data* the directive carries to the cascade via the synthetic signal. If a future principle argues even that's a runtime-state mutation, the cascade can do its own monitoring (the synthetic signal would carry `pid` only). Defer until that case is real.
