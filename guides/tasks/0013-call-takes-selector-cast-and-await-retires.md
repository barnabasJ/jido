# Task 0013 — `AgentServer.call/4` takes a selector; `cast_and_await/4` retires; state-returning `call/3` deleted

- Implements: [ADR 0020](../adr/0020-synchronous-call-takes-a-selector.md)
- Depends on: [task 0009](0009-pod-mutate-cast-await-api.md) (shipped) — `Pod.mutate*` already use `cast_and_await/4` so this task is the migration off it.
- Blocks: [task 0010](0010-pod-runtime-signal-driven-state-machine.md) — `mutate_and_wait/3`'s queued-ack step lands on `call/4` from the start, no double rewrite.
- Leaves tree: **green**

## Goal

Replace `AgentServer.cast_and_await/4` and the state-returning `AgentServer.call/3` with a unified `AgentServer.call/4` that always takes a selector. Delete the ack-table machinery (`pending_acks`, `register_ack` / `cancel_ack` handlers, `drop_dead_pending_ack/2`, `fire_ack_for_signal/3`). Extract the signal-pipeline logic into a `process_signal/2` helper callable from both `handle_cast({:signal, ...})` and the new `handle_call({:signal_with_selector, ...})`.

Per [ADR 0020](../adr/0020-synchronous-call-takes-a-selector.md): synchronous interaction with an agent always carries a caller-provided selector. The boundary-shaping is the caller's choice; the server runs the projection and replies with its result.

After this task `AgentServer`'s public surface is:

| | Synchronous? | Selector? | Returns |
|---|---|---|---|
| `cast/2` | no | no | `:ok` |
| `call/4` | yes | required | `{:ok, value}` / `{:error, reason}` from selector or framework error |
| `subscribe/4` | no (ambient) | required | dispatched per-event |
| `state/1` | yes | no — debug only | `{:ok, %State{}}` (kept per ADR 0006 for liveness/bootstrap) |

## Files to modify

### `lib/jido/agent_server.ex`

**Add `call/4`:**

```elixir
@typedoc """
Selector for `call/4`. Same calling convention as `subscribe/4`'s selector
but without `:skip` — the caller is blocking, so "skip" has no meaning.
"""
@type call_selector :: (State.t() -> {:ok, term()} | {:error, term()})

@spec call(server(), Signal.t(), call_selector(), keyword()) ::
        {:ok, term()} | {:error, term()}
def call(server, %Signal{} = signal, selector, opts \\ [])
    when is_function(selector, 1) do
  timeout = Keyword.get(opts, :timeout, Defaults.agent_server_call_timeout_ms())
  with {:ok, pid} <- resolve_server(server) do
    GenServer.call(pid, {:signal_with_selector, signal, selector}, timeout)
  end
end
```

**Add the matching handler:**

```elixir
def handle_call({:signal_with_selector, %Signal{} = signal, selector}, _from, state)
    when is_function(selector, 1) do
  case process_signal(state, signal) do
    {:ok, new_state, _directives} ->
      {:reply, selector.(new_state), new_state}

    {:error, committed_state, reason} ->
      # ADR 0018 §1: middleware-staged ctx.agent commits unconditionally;
      # selector is NOT invoked on error path per ADR 0018 §3.
      {:reply, {:error, reason}, committed_state}
  end
end
```

**Extract `process_signal/2`** from the existing `handle_cast({:signal, ...})` body. It runs the middleware chain, applies the result to state, runs `fire_post_signal_hooks/3`, returns `{:ok, new_state, directives} | {:error, committed_state, reason}`. Both `handle_cast` and the new `handle_call` go through it.

```elixir
@spec process_signal(State.t(), Signal.t()) ::
        {:ok, State.t(), [struct()]} | {:error, State.t(), term()}
defp process_signal(%State{} = state, %Signal{} = signal) do
  # existing chain-running logic here, returning the committed state and
  # the chain result. Today this is inline in handle_cast; task 0013
  # extracts it.
end
```

`handle_cast({:signal, signal})` becomes:

```elixir
def handle_cast({:signal, signal}, state) do
  case process_signal(state, signal) do
    {:ok, new_state, _dirs} -> {:noreply, new_state}
    {:error, committed_state, _reason} -> {:noreply, committed_state}
  end
end
```

**Delete:**

- `cast_and_await/4` ([agent_server.ex:411-446](../../lib/jido/agent_server.ex)) — caller side
- `call/3` ([agent_server.ex:319-324](../../lib/jido/agent_server.ex)) — state-returning version
- `handle_call({:register_ack, ...}, ...)` ([agent_server.ex:1175-1191](../../lib/jido/agent_server.ex))
- `handle_cast({:cancel_ack, ...}, ...)` (if present)
- `drop_dead_pending_ack/2` and its `:DOWN` handler branch
- `fire_ack_for_signal/3` ([agent_server.ex:1848-1865](../../lib/jido/agent_server.ex))

**Simplify `fire_post_signal_hooks/3`** to call only `fire_subscribers/2`:

```elixir
defp fire_post_signal_hooks(%State{} = state, %Signal{} = signal, _result) do
  fire_subscribers(state, signal)
end
```

### `lib/jido/agent_server/state.ex`

**Delete the `pending_acks` field** (currently around line 98 per the comment "Map of signal id => %{caller_pid, ref, monitor_ref, selector} for cast_and_await"). Remove from struct definition, default value, and any `%State{pending_acks: ...}` constructions in tests.

### `lib/jido/pod/mutable.ex`

**Migrate `mutate/3`** from `cast_and_await/4` to `call/4`:

```elixir
@spec mutate(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
        {:ok, %{mutation_id: String.t(), queued: true}} | {:error, term()}
def mutate(server, ops, opts \\ []) when is_list(opts) do
  signal =
    Signal.new!(
      "pod.mutate",
      %{ops: ops, opts: Map.new(opts)},
      source: "/jido/pod/mutate"
    )

  call_timeout =
    Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, :timer.seconds(30)))

  selector = Keyword.get(opts, :selector, &default_selector/1)

  AgentServer.call(server, signal, selector, timeout: call_timeout)
end
```

**Migrate `mutate_and_wait/3`** to use `call/4` for the queued-ack step. The subscription step is unchanged (still uses `subscribe/4`). The receive loop and selectors are unchanged.

(Note: task 0010 also redesigns `mutate_and_wait/3` to subscribe to natural child lifecycle signals instead of the synthetic `jido.pod.mutate.{completed,failed}`. Task 0013 + 0010 layer cleanly: 0013 changes the queued-ack primitive; 0010 changes the lifecycle-signal pattern.)

### `lib/jido/pod.ex`

Update the doc reference at [pod.ex:204](../../lib/jido/pod.ex):

```diff
-  `Jido.AgentServer.call/3`. Pass the running pod pid, ...
+  `Jido.AgentServer.call/4`. Pass the running pod pid, ...
```

### `lib/jido.ex`

Update the doc reference at [jido.ex:55](../../lib/jido.ex):

```diff
-  signal-driven runtime (including the `cast_and_await/4` and
+  signal-driven runtime (including the `call/4` and
```

### `lib/jido/config/defaults.ex`

Update the docstring at [defaults.ex:52](../../lib/jido/config/defaults.ex) to drop `cast_and_await/4`:

```diff
-  @doc "Default timeout for AgentServer waiting primitives (cast_and_await/4, await_child/3, await_ready/2)."
+  @doc "Default timeout for AgentServer waiting primitives (call/4, await_child/3, await_ready/2)."
```

### `lib/jido/agent/worker_pool.ex`

5 callsites of `AgentServer.call/3` (lines 39, 40, 79, 84, 125, 170). Each takes the resulting `{:ok, agent}` and either discards the agent or extracts a field. Each must migrate to a selector:

```elixir
# Before
{:ok, _agent} = Jido.AgentServer.call(pid, signal)

# After
{:ok, _value} = Jido.AgentServer.call(pid, signal, fn _state -> {:ok, :done} end)
```

Audit each callsite. If the caller cared about a specific field, reflect that in the selector. If they just wanted "did the signal complete," return `:done` or `:ok`.

The pool-level `WorkerPool.call/3` API itself becomes:

```elixir
@spec call(name(), Signal.t(), AgentServer.call_selector(), keyword()) ::
        {:ok, term()} | {:error, term()}
def call(pool, signal, selector, opts \\ []) do
  # checkout, AgentServer.call(pid, signal, selector, opts), checkin
end
```

### `lib/jido/signal/call.ex`

Update the comparison at [call.ex:35](../../lib/jido/signal/call.ex):

```diff
-  ## Why not `Jido.AgentServer.call/2`?
-
-  `AgentServer.call/2` does synchronously dispatch a signal, but it
+  ## Why not `Jido.AgentServer.call/4`?
+
+  `AgentServer.call/4` does synchronously dispatch a signal with a
+  selector, but it
```

Plus the rationale text — `call/4`'s output is whatever the caller's selector returns; `Signal.Call.call/3` is request/reply with a server-shaped reply via `%Directive.Reply{}`. Both still coexist; the comparison just updates to the new shape.

### Tests

**`test/examples/plugins/plugin_basics_test.exs`** — 4 callsites (lines 135, 146, 149, 159) of `AgentServer.call/3` returning `{:ok, agent}`. Each follows up by reading `agent.state.notes` or similar. Migrate to selectors:

```elixir
# Before
{:ok, agent} = AgentServer.call(pid, signal)
assert agent.state.notes == [...]

# After
{:ok, notes} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent.state.notes} end)
assert notes == [...]
```

**`test/examples/signals/context_aware_routing_test.exs`** — ~7 callsites. Same pattern.

**`test/jido/agent_server/cron_integration_test.exs`** — 2 callsites at lines 214, 247. Most discard the agent (`{:ok, _agent}`) — replace with `fn _ -> {:ok, :done} end` selector.

**`test/jido/pod/mutation_runtime_test.exs`** — 1 callsite at line 396 (`AgentServer.call(pod_pid, Signal.new!("expand", ...))`). Extract whatever this test cares about (the test follows up with `eventually_state` polling, so the call itself is just a sync barrier — selector returns `{:ok, :done}` is fine).

**Audit** the rest of `test/` for `AgentServer.call(` and migrate. `grep -rn "AgentServer.call(" test/` should give the full list.

**`test/jido/agent_server/`** — any tests that exercised `cast_and_await/4` directly need to migrate to `call/4`. The test for "ack fires after pipeline" survives in spirit but tests the `call/4` reply path instead. Tests for ack-table cleanup (caller dies, timeout, monitor down) get deleted along with the implementations.

## Files to create

None.

## Files to delete

None (all changes are in-place).

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix test` — full suite passes.
- `grep -rn "cast_and_await" lib/ test/` returns no hits (other than this task doc + ADR 0020 / commit messages).
- `grep -rn "AgentServer.call(" lib/ test/` shows only `call/4` callsites (3-arity gone).
- `state.pending_acks` field is gone from `Jido.AgentServer.State`.
- `pod_pid |> AgentServer.call(signal, selector)` is the canonical synchronous-with-answer pattern; nothing returns `{:ok, %Agent{}}` from the framework anymore.

## Out of scope

- **`AgentServer.state/1` redesign.** Per [ADR 0006](../adr/0006-external-sync-uses-signals.md) and [ADR 0020](../adr/0020-synchronous-call-takes-a-selector.md) §5, `state/1` is kept as a debug/bootstrap primitive. If it shows up as a load-bearing channel in normal traffic, that's a smell to fix later — not in this task.

- **`Jido.Signal.Call.call/3`.** Different semantics (request/reply with `%Directive.Reply{}`); coexists with `call/4`. Not touched.

- **Pool-level helpers in `Jido.AgentServer.Pool`** (if any beyond `WorkerPool`). Audit during implementation; if found, migrate the same way.

- **Migration of `Pod.mutate_and_wait/3` to subscribe to natural child lifecycle signals.** That's [task 0010](0010-pod-runtime-signal-driven-state-machine.md). This task only changes the queued-ack primitive (cast_and_await → call); the subscription pattern stays as-is from task 0009 until 0010 lands.

## Risks

- **`process_signal/2` extraction.** The existing `handle_cast({:signal, ...})` body has accumulated logic — middleware chain composition, directive application, fire_post_signal_hooks, error reshaping. Extracting cleanly without changing semantics is the trickiest part of this task. Recommended: extract first as a pure refactor (still using `cast_and_await/4`), verify tests stay green, *then* delete the ack-table code and add the new `call/4` handler.

- **GenServer.call timeout edge case.** If the caller times out, the GenServer might still process the message and try to reply. The reply lands on a dead pid (caller went away after demonitor or process exit) and is GC'd. Document this as expected behavior in the `call/4` docstring. Mention that callers needing precise cleanup semantics should use `cast/2` + `subscribe/4` for the truly-async pattern.

- **Worker pool refactor surface.** `WorkerPool.call/3` callers are out-of-tree (apps using Jido as a library). Per NO-LEGACY-ADAPTERS, no shim — they break and migrate. The migration recipe is mechanical: every caller adds a selector. Document the rename in the changelog.

- **Test coverage for the deleted ack-table.** A handful of tests likely exercise `cast_and_await`'s timeout / cancel / monitor-down behavior. Those tests are testing implementation details of code that's getting deleted — they go away with it. Don't try to preserve them; the new behavior is "GenServer.call timeout."

- **Order with task 0010.** Land 0013 *before* 0010. Task 0010's `Pod.Mutable.mutate_and_wait/3` rewrite assumes `call/4` exists; if 0010 lands first, it has to use `cast_and_await/4` and immediately gets rewritten by 0013. The README dependency chain (0011 → 0009 → 0012 → 0013 → 0010) reflects this.

- **Selector errors via `try/rescue`.** Today, the ack table catches selector raises and surfaces them as errors to the caller. With direct `GenServer.call`, if a selector raises in `handle_call`, the GenServer crashes and the caller sees `{:noproc, ...}` instead of a clean error. Wrap the selector call in `try/rescue` inside `handle_call({:signal_with_selector, ...})` and reply `{:error, {:selector_raised, exception, stacktrace}}` on rescue.

- **Documentation drift.** `cast_and_await/4` and the state-returning `call/3` are mentioned in ADR 0016, ADR 0017, ADR 0018, ADR 0020 (this ADR), and several module docstrings. Update each. ADR 0016's §1 should be marked superseded by ADR 0020 (already done in ADR 0020 frontmatter; verify ADR 0016 cross-links back).
