# Task 0009 — `Pod.mutate` switches to `cast_and_await` + lifecycle signals; add `Pod.mutate_and_wait/3`

- Implements: [ADR 0017](../adr/0017-pod-mutations-are-signal-driven.md) Phase 1 — the public API surface
- Depends on: ADR 0017 + ETS lock deletion landed (commit `fdd59cf`). **Also requires [task 0011](0011-tagged-tuple-return-shape.md) (ADR 0018) to have landed first** — the default selector below assumes the framework delivers action errors automatically via the tagged-tuple return.
- Blocks: [task 0010](0010-pod-runtime-signal-driven-state-machine.md)
- Leaves tree: **green**

## Goal

Make `Pod.mutate/3` return immediately with a `{:ok, %{mutation_id, queued: true}}` ack via `cast_and_await/4`, and emit `jido.pod.mutate.completed` / `jido.pod.mutate.failed` lifecycle signals at the end of the existing synchronous `execute_mutation_plan/3`. Add `Pod.mutate_and_wait/3` for callers that want the report — internally, subscribe-then-cast-then-receive over the lifecycle signal pattern.

The wave-orchestration machinery in `Jido.Pod.Runtime` is **untouched** by this task. The mailbox still blocks during `execute_mutation_plan`. That blocking is removed in [task 0010](0010-pod-runtime-signal-driven-state-machine.md). What changes here is purely the public API contract and the addition of lifecycle signals so that callers and subscribers can adopt the right pattern *before* the underlying runtime is refactored.

This sequencing matters: with the API correct, task 0010 becomes a pure internal-rewrite — caller code doesn't change again.

## Files to modify

### `lib/jido/pod/runtime.ex`

In `execute_mutation_plan/3` (the function that completes the mutation slice update), after the mutation status is computed and just before the function returns, emit a lifecycle signal:

```elixir
# In execute_mutation_plan/3, after `mutation_state` is built (~line 169),
# before the agent_state is updated:

lifecycle_signal =
  Signal.new!(
    "jido.pod.mutate.#{mutation_status}",  # :completed or :failed
    %{
      mutation_id: plan.mutation_id,
      report: report,
      error: if(mutation_status == :failed, do: report, else: nil)
    },
    source: "/pod/#{state.id}"
  )

_ = AgentServer.cast(self(), lifecycle_signal)
```

The cast is to `self()` — the pod's own AgentServer pid. The signal flows back through the pod's own pipeline; subscribers attached to `jido.pod.mutate.completed` / `.failed` see it after the outermost middleware unwinds (per [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md) hook point).

**Note**: because `execute_mutation_plan` runs inline in `ApplyMutation.exec/3` — which itself runs inside the outer signal pipeline — the lifecycle signal lands in the pod's mailbox *after* the current pipeline finishes. By the time it's processed, `mutation.status` is already `:completed`/`:failed` in slice state (the StateOp directives that updated the slice were applied earlier in the current pipeline). Subscribers can read state freely.

### `lib/jido/pod/mutable.ex`

Replace `mutate/3` with the queued-ack flavor. `Pod.mutate/3` ships a **default selector** baked in — most callers don't pass one. Power users override via the `selector:` opt:

```elixir
@spec mutate(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
        {:ok, term()} | {:error, term()}
def mutate(server, ops, opts \\ []) when is_list(opts) do
  signal =
    Signal.new!(
      "pod.mutate",
      %{ops: ops, opts: Map.new(opts)},
      source: "/jido/pod/mutate"
    )

  await_timeout =
    Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, :timer.seconds(30)))

  selector = Keyword.get(opts, :selector, &default_selector/1)

  AgentServer.cast_and_await(server, signal, selector, timeout: await_timeout)
end

# Default selector returns the signal's mutation_id and a "queued" marker.
# Most callers want this; override via `selector:` opt for a different projection.
defp default_selector(%{agent: %{state: agent_state}}) do
  %{id: id} = get_in(agent_state, [@pod_state_key, :mutation])
  {:ok, %{mutation_id: id, queued: true}}
end
```

Per [ADR 0018](../adr/0018-tagged-tuple-return-shape.md): "the selector is the *query* — different callers want different projections of the success-path state. The error is always the same — the action either succeeded or it didn't, and the framework owns delivery either way." The default selector is the common-case query; the framework delivers `{:error, :mutation_in_progress}` automatically when the action's `ensure_mutation_idle/1` rejects, so the selector never has to encode a synchronous-failure branch.

The selector reads `mutation.id` directly without status-guarding because the action's StateOp directives have already set the slice before the selector runs (per [ADR 0016](../adr/0016-agent-server-ack-and-subscribe.md) hook point — selector fires after the outermost middleware unwinds and directives have been applied).

Add `mutate_and_wait/3`:

```elixir
@spec mutate_and_wait(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
        {:ok, Jido.Pod.mutation_report()} | {:error, term()}
def mutate_and_wait(server, ops, opts \\ []) when is_list(opts) do
  await_timeout =
    Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, :timer.seconds(30)))

  signal =
    Signal.new!(
      "pod.mutate",
      %{ops: ops, opts: Map.new(opts)},
      source: "/jido/pod/mutate"
    )

  # Subscribe FIRST. Race-free: the lifecycle signal can't fire before the trigger
  # signal is processed, and the subscription registers in a synchronous GenServer.call.
  # Filter via signal.id which the action passes through into mutation_id.
  expected_signal_id = signal.id

  with {:ok, sub_ref} <-
         AgentServer.subscribe(
           server,
           "jido.pod.mutate.completed",
           &mutate_completion_selector(&1, expected_signal_id),
           once: true
         ),
       {:ok, fail_ref} <-
         AgentServer.subscribe(
           server,
           "jido.pod.mutate.failed",
           &mutate_failure_selector(&1, expected_signal_id),
           once: true
         ) do
    cast_result =
      AgentServer.cast_and_await(server, signal, &default_selector/1, timeout: await_timeout)

    case cast_result do
      {:ok, %{queued: true}} ->
        wait_for_lifecycle(server, sub_ref, fail_ref, await_timeout)

      {:error, _reason} = error ->
        AgentServer.unsubscribe(server, sub_ref)
        AgentServer.unsubscribe(server, fail_ref)
        error
    end
  end
end

defp mutate_completion_selector(%{agent: %{state: agent_state}}, expected_id) do
  case get_in(agent_state, [@pod_state_key, :mutation]) do
    %{id: ^expected_id, status: :completed, report: report} -> {:ok, report}
    _ -> :skip
  end
end

defp mutate_failure_selector(%{agent: %{state: agent_state}}, expected_id) do
  case get_in(agent_state, [@pod_state_key, :mutation]) do
    %{id: ^expected_id, status: :failed, error: error} -> {:error, error}
    _ -> :skip
  end
end

defp wait_for_lifecycle(server, sub_ref, fail_ref, timeout) do
  receive do
    {:jido_subscription, ^sub_ref, %{result: {:ok, report}}} ->
      AgentServer.unsubscribe(server, fail_ref)
      {:ok, report}

    {:jido_subscription, ^fail_ref, %{result: {:error, error}}} ->
      AgentServer.unsubscribe(server, sub_ref)
      {:error, error}
  after
    timeout ->
      AgentServer.unsubscribe(server, sub_ref)
      AgentServer.unsubscribe(server, fail_ref)
      {:error, :timeout}
  end
end
```

**Subtle point on `mutation_id == signal.id`**: the existing `Mutation.Planner.plan/2` generates its own `mutation_id` (UUID). For `mutate_and_wait` to filter via the trigger signal's id, the action handler must use `signal.id` as the mutation_id rather than letting Planner generate one.

Update `Pod.Actions.Mutate.run/4`:

```elixir
def run(%Jido.Signal{id: signal_id, data: %{ops: ops, opts: opts}}, _slice, _opts, ctx) do
  with {:ok, effects} <- Pod.mutation_effects(ctx.agent, ops, Map.to_list(opts || %{}), mutation_id: signal_id) do
    {:ok, %{mutation_queued: true, mutation_id: signal_id}, effects}
  end
end
```

And update `Pod.Mutable.mutation_effects/3` (and through it, `Planner.plan/2`) to accept `mutation_id` from opts:

```elixir
# In Planner.plan/2 (lib/jido/pod/mutation/planner.ex):
def plan(topology, ops, opts \\ []) do
  mutation_id = Keyword.get(opts, :mutation_id) || generate_mutation_id()
  # ... rest unchanged
end
```

This is the only material change to Planner: external mutation_id wins, generated id is the fallback.

### `lib/jido/pod.ex`

Add a defdelegate for `mutate_and_wait`:

```elixir
@spec mutate_and_wait(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
        {:ok, mutation_report()} | {:error, term()}
defdelegate mutate_and_wait(server, ops, opts \\ []), to: Mutable
```

Update the `mutate/3` `@spec` to reflect the new return shape:

```elixir
@spec mutate(AgentServer.server(), [Mutation.t() | term()], keyword()) ::
        {:ok, %{mutation_id: String.t(), queued: true}} | {:error, term()}
defdelegate mutate(server, ops, opts \\ []), to: Mutable
```

### `lib/jido/pod/plugin.ex`

Extend `signal_routes` so subscribers attached to the lifecycle signals match the patterns the AgentServer dispatches against. Currently the plugin doesn't need to *handle* the lifecycle signals (`execute_mutation_plan` already updates the slice), but the patterns must be in `signal_routes` for `subscribe/4` to dispatch to subscribers per [ADR 0016 §2 "subscribe/4"](../adr/0016-agent-server-ack-and-subscribe.md).

Actually — re-reading ADR 0016: subscribe doesn't *require* the signal type to be in `signal_routes`. The subscription router is independent. **No change needed in `plugin.ex` for this task.** The signal_routes entry would only be needed if we wanted an action to run; for now we just want subscribers to observe.

Skip this section. Confirm by reading `AgentServer.subscribe/4` — pattern matching is independent of `signal_routes` registration.

### `test/jido/pod/mutation_runtime_test.exs`

Existing tests assert on the synchronous report return:

```elixir
assert {:ok, report} = Pod.mutate(pod_pid, add_ops)
```

These break under the new contract. Two options per test:

1. If the test cares about the mutation completing (most do), switch to `mutate_and_wait`:

   ```elixir
   assert {:ok, report} = Pod.mutate_and_wait(pod_pid, add_ops)
   ```

2. If the test wants to verify the queued-ack semantics specifically, assert the new shape and then explicitly wait via lifecycle signal:

   ```elixir
   assert {:ok, %{mutation_id: id, queued: true}} = Pod.mutate(pod_pid, add_ops)
   ```

Default to option 1 unless the test name explicitly mentions queueing/dispatching. Search in the test file for every `Pod.mutate(` callsite and convert.

### `test/jido/pod/runtime_test.exs`

Same conversion for any `Pod.mutate` calls.

### `test/jido/pod/telemetry_test.exs`

Likely no changes (telemetry on the runtime layer doesn't hit the API contract).

## Files to create

None.

## Files to delete

None.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix test test/jido/pod/` — all 35 pod tests pass after rewriting `Pod.mutate` callsites to `Pod.mutate_and_wait` (or asserting the queued ack shape).
- `mix test` — full suite passes.
- New scratch test (optional, written into `mutation_runtime_test.exs`):

  ```elixir
  test "Pod.mutate returns immediately with mutation_id; lifecycle signal carries report" do
    {:ok, pod_pid} = start_pod(...)

    {:ok, %{mutation_id: id, queued: true}} =
      Pod.mutate(pod_pid, [Mutation.add_node(...)])

    {:ok, _ref} =
      AgentServer.subscribe(pod_pid, "jido.pod.mutate.completed",
        fn s ->
          case get_in(s.agent.state, [:pod, :mutation]) do
            %{id: ^id, status: :completed, report: r} -> {:ok, r}
            _ -> :skip
          end
        end,
        once: true)

    # the subscribe-then-receive flow returns the report
    assert_receive {:jido_subscription, _ref, %{result: {:ok, %{...}}}}, 5_000
  end
  ```

  But because `execute_mutation_plan` runs inline in this phase, the mutation has *already finished* by the time `cast_and_await` returns its ack. The lifecycle signal landed in the mailbox earlier; the subscriber registered after. So this scratch test would actually fail under Phase 1 — it's a Phase 2 acceptance test. Skip it for now; subscribers are correctly behaved only after task 0010 unblocks the mailbox.

  **Use `Pod.mutate_and_wait` for tests that need the report.** It internally subscribes *before* casting, so the race doesn't apply.

- Concurrent-mutate rejection: a second `Pod.mutate` call while the first is in-flight returns `{:error, :mutation_in_progress}` directly via the ack. The first one (which does the actual work synchronously in this phase) has to finish before the second can be issued — but a test that *somehow* squeezes a second cast in (e.g. by using a deliberately slow mount plugin in the topology) demonstrates the rejection.

## Out of scope

- **Moving `execute_mutation_plan` to a Task** — task 0010.
- **Deleting wave-orchestration machinery in `Runtime`** — task 0010.
- **`Jido.Pod.Directive.ApplyMutation` deletion** — task 0010 (it stays in this task; `execute_mutation_plan` still runs through it).
- **New `StartNode`/`StopNode` directives** — task 0010.
- **`signal_routes` for child-lifecycle progression** — task 0010 (no signal-driven state machine yet in this phase).

## Risks

- **`signal.id` as mutation_id**: existing code paths assume Planner generates the id. Audit `Planner.plan/2` and any consumers (e.g. report-building helpers) for hardcoded id-shape assumptions. Signal IDs are UUIDs, same shape as the existing generated ids, so the wire shape is identical.

- **`mutate_and_wait` two-subscription overhead**: subscribing to `.completed` and `.failed` separately is a small overhead. An alternative is one subscription to `jido.pod.mutate.*` with a selector that distinguishes by signal type — but selector receives state only, not the signal, per [ADR 0016 §2](../adr/0016-agent-server-ack-and-subscribe.md). The two-subscription approach is cleaner.

- **Lifecycle signal dispatch ordering**: `AgentServer.cast(self(), signal)` from inside `execute_mutation_plan` — which itself runs inside `ApplyMutation.exec/3` — pushes the signal into the mailbox. It's processed *after* the current pipeline (with all its directives) fully returns to the GenServer loop. The mutation slice is updated in the current pipeline (StateOp directives), so by the time the lifecycle signal is processed, the slice already reflects `:completed`/`:failed` and the subscribers' selectors see the right state.

- **Telemetry on lifecycle signals**: pre-existing `pod.reconcile.{started,completed,failed}` use `emit_pod_lifecycle/4` which formats source as `/pod/#{state.id}` and goes via `AgentServer.cast`. Use the same path/conventions for the mutate lifecycle signals.

- **Test semantics shift**: previously, a synchronous `Pod.mutate` return meant "the mutation completed and here's the report." Tests that hold onto the report and immediately query state (`Pod.nodes(pod_pid)` etc.) work fine because `mutate_and_wait` waits for the same point. Tests that asserted on telemetry timing or signal ordering may need to acknowledge the queued-ack now lands earlier.

- **`@pod_state_key` inside a closure passed to `subscribe/4`**: the selector closure references the module attribute. Make sure the closure is built with the resolved value (not the attribute reference re-evaluated in another module). Standard module-attribute behavior — inlined at compile time — handles this correctly.
