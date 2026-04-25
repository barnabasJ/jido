# Task 0011 — Tagged-tuple return shape across action / cmd / middleware

- Implements: [ADR 0018](../adr/0018-tagged-tuple-return-shape.md) — unified return shape, all-or-nothing batches, ack reads chain outcome
- Depends on: ADRs 0014/0015/0016 shipped (commits through `99f2cdb`). Independent of [task 0009](0009-pod-mutate-cast-await-api.md) and [task 0010](0010-pod-runtime-signal-driven-state-machine.md) — can land before, after, or interleaved.
- Blocks: nothing
- Leaves tree: **green**

## Goal

Unify action / cmd / middleware return shapes to `{:ok, t, [directive]} | {:error, reason}`. Make multi-instruction `cmd` all-or-nothing. Plumb the chain's tagged outcome into `fire_post_signal_hooks` so `cast_and_await` callers receive `{:error, reason}` automatically when actions fail. Simplify Retry middleware to pattern-match the chain return.

One commit, no intermediate-broken states. The contract change touches a connected set of files; partial conversions would leak the old shape.

## Files to modify

### `lib/jido/action.ex`

Update the `run/4` typespec and module docs. The new contract:

```elixir
@callback run(Jido.Signal.t(), slice :: term(), opts :: keyword(), ctx :: map()) ::
            {:ok, new_slice :: term(), [Jido.Directive.t()]} | {:error, term()}
```

No `{:ok, slice}` two-arg, no `{:ok, slice, directive}` (single, unwrapped). Always `{:ok, slice, [directive]}`. Always a list, even if empty.

Update example snippets in moduledoc to use the new shape.

### `lib/jido/agent.ex`

Two changes:

1. **`cmd/2,3` typespec + return shape.** Today returns `{agent, [directive]}`. New:

   ```elixir
   @spec cmd(Jido.Agent.t(), action() | [action()], keyword()) ::
           {:ok, Jido.Agent.t(), [Jido.Directive.t()]} | {:error, term()}
   ```

2. **`__run_cmd_loop__` switches to `reduce_while`** with halt-on-error:

   ```elixir
   defp __run_cmd_loop__(initial_agent, instructions, jido_instance) do
     Enum.reduce_while(instructions, {:ok, initial_agent, []}, fn
       instruction, {:ok, acc_agent, acc_dirs} ->
         case __run_instruction__(acc_agent, instruction, jido_instance) do
           {:ok, new_agent, new_dirs} ->
             {:cont, {:ok, new_agent, acc_dirs ++ List.wrap(new_dirs)}}

           {:error, _reason} = err ->
             {:halt, err}
         end
     end)
   end
   ```

   Drop the existing path that synthesizes `%Directive.Error{}` from `{:error, _}` action returns. The error propagates as the cmd's outcome instead.

3. **`__run_instruction__`** returns the tagged tuple `{:ok, new_agent, dirs} | {:error, reason}`. Wrap raw errors into `%Jido.Error{}` (or pass through if already wrapped) — see "Error wrapping" below.

### `lib/jido/middleware.ex`

Update `@callback on_signal` typespec to the new return shape:

```elixir
@callback on_signal(
            Jido.Signal.t(),
            ctx :: map(),
            opts :: keyword(),
            next :: (Jido.Signal.t(), map() -> {:ok, map(), [Jido.Directive.t()]} | {:error, term()})
          ) :: {:ok, map(), [Jido.Directive.t()]} | {:error, term()}
```

`next.(signal, ctx)` returns the tagged tuple. Middleware that wraps `next` returns the tagged tuple.

### `lib/jido/middleware/retry.ex`

Today: scans `dirs` for `%Directive.Error{}`. New:

```elixir
def on_signal(signal, ctx, opts, next) do
  attempts = Keyword.get(opts, :attempts, 1)
  do_attempt(signal, ctx, opts, next, attempts)
end

defp do_attempt(signal, ctx, opts, next, attempts_left) do
  case next.(signal, ctx) do
    {:error, _reason} when attempts_left > 1 ->
      :timer.sleep(backoff(opts, attempts_left))
      do_attempt(signal, ctx, opts, next, attempts_left - 1)

    other ->
      other
  end
end
```

Spurious-fire fix: a user-emitted `%Error{}` directive on the success path no longer triggers retry. Retry only fires on actual `{:error, _}` chain returns.

### `lib/jido/middleware/persister.ex`

Update return shapes to tagged tuples. The `before_signal` / `after_signal` style hooks should now return `{:ok, ctx, []}` on success and `{:error, reason}` on failure.

Lifecycle-signal-emit side effects (the `jido.persist.thaw.failed` / `.hibernate.failed` emits) stay verbatim — they're observability for lifecycle signals, not for the request/response path.

### `lib/jido/agent_server.ex`

Multi-piece change. The chain's tagged tuple becomes the source of truth.

1. **`core_next` returns the tagged tuple.** Currently it runs the cmd reducer and constructs a directive list. After: returns `{:ok, ctx, dirs} | {:error, reason}`.

2. **`emit_through_chain` (or wherever the middleware chain is invoked) reads the tagged tuple.**

   ```elixir
   case chain.(signal, ctx) do
     {:ok, new_ctx, dirs} ->
       state = State.update_agent(state, new_ctx.agent)
       {:ok, state} = execute_directives(dirs, signal, state)
       state = fire_post_signal_hooks(state, signal, {:ok, new_ctx, dirs})
       {:ok, state}

     {:error, _reason} = err ->
       state = fire_post_signal_hooks(state, signal, err)
       {:ok, state}    # the agent state is unchanged; only acks/subscribers fire
   end
   ```

   Note: `State.update_agent` and `execute_directives` only run on `:ok`. On `:error`, the agent's state is untouched.

3. **`fire_post_signal_hooks/3`** (was `/2`):

   ```elixir
   defp fire_post_signal_hooks(state, signal, result) do
     state = fire_ack_for_signal(state, signal, result)
     state = fire_subscribers(state, signal)
     state
   end

   defp fire_ack_for_signal(state, %Signal{id: id}, result) do
     case Map.pop(state.pending_acks, id) do
       {nil, _} ->
         state

       {ack, acks} ->
         payload =
           case result do
             {:ok, _ctx, _dirs} -> ack.selector.(state.agent.state)
             {:error, _reason} = err -> err
           end

         send(ack.caller_pid, {:jido_ack, ack.ref, payload})
         Process.demonitor(ack.monitor_ref, [:flush])
         %{state | pending_acks: acks}
     end
   end
   ```

   `fire_subscribers/2` is unchanged — subscribers always run their selector against state, independent of the chain outcome.

### `lib/jido/exec.ex`

If `Jido.Exec.run/N` is exposed for direct action invocation outside the agent (developer-affordance entry point per [tasks/README §NO-LEGACY-ADAPTERS](README.md)), propagate the new shape: returns `{:ok, slice, [directive]} | {:error, reason}`.

### Error wrapping

In `__run_instruction__` (and any other ingress where a non-conforming `{:error, _}` could arrive), normalize:

```elixir
defp normalize_error({:error, %Jido.Error{} = e}), do: {:error, e}
defp normalize_error({:error, reason}), do: {:error, Jido.Error.from_term(reason)}
```

`Jido.Error.from_term/1` wraps an arbitrary term as `%Jido.Error{kind: :unknown, message: inspect(term), details: %{raw: term}}` if it isn't already structured. This gives consumers a stable shape without forcing every action author to construct a `%Jido.Error{}` by hand.

If `Jido.Error.from_term/1` doesn't exist yet, add it as a tiny helper in this same commit.

## Files to create

None (or one tiny helper in `lib/jido/error.ex` if `from_term/1` doesn't exist; check first).

## Files to delete

None.

## Tests to add

### `test/jido/agent/agent_test.exs`

```elixir
test "multi-instruction cmd returns ok with concatenated directives on full success" do
  agent = build_agent()
  assert {:ok, new_agent, dirs} = MyAgent.cmd(agent, [{ActA, %{}}, {ActB, %{}}])
  assert new_agent.state.slice.a_done
  assert new_agent.state.slice.b_done
  assert length(dirs) == 1  # whatever ActA + ActB emit
end

test "multi-instruction cmd halts on first error; agent unchanged, no directives" do
  agent = build_agent()
  assert {:error, %Jido.Error{}} = MyAgent.cmd(agent, [{ActA, %{}}, {Failing, %{}}, {ActB, %{}}])
  # original agent unchanged — ActA's slice changes vanished
  refute Map.has_key?(agent.state.slice, :a_done)
end

test "single-instruction cmd unchanged: success returns {:ok, agent, dirs}" do
  agent = build_agent()
  assert {:ok, new_agent, []} = MyAgent.cmd(agent, {ActA, %{}})
end

test "single-instruction cmd unchanged: error returns {:error, reason}" do
  agent = build_agent()
  assert {:error, %Jido.Error{}} = MyAgent.cmd(agent, {Failing, %{}})
end
```

### `test/jido/agent_server/ack_subscribe_test.exs`

```elixir
test "cast_and_await receives {:error, reason} when action errors" do
  {:ok, pid} = start_agent()

  signal = Signal.new!("trigger.failing", %{})
  result = AgentServer.cast_and_await(pid, signal, &impossible_selector/1, timeout: 1_000)

  assert {:error, %Jido.Error{}} = result
end

test "cast_and_await success path: selector runs, value crosses boundary" do
  # unchanged behavior; existing tests cover this
end

test "subscribers' selectors run on the same signal even when the action errored" do
  {:ok, pid} = start_agent()

  {:ok, ref} = AgentServer.subscribe(pid, "trigger.failing", &observer_selector/1)

  AgentServer.cast(pid, Signal.new!("trigger.failing", %{}))

  assert_receive {:jido_subscription, ^ref, %{result: _}}, 1_000
end

test "Retry middleware re-invokes next on {:error, _} chain return; final error reaches caller once" do
  # signal triggers an action that errors twice then succeeds (or fails N times)
  # caller hears one ack
end
```

### `test/jido/middleware/retry_test.exs`

Replace fixtures that constructed `%Directive.Error{}` with fixtures that return `{:error, _}` from `next`. Confirm Retry now triggers on the chain return. Add a test: a user-emitted `%Error{}` directive on the success path does NOT trigger Retry.

### `test/jido/middleware_test.exs`

```elixir
test "middleware that swallows {:error, _} and returns {:ok, ctx, []} propagates as success to the ack" do
  # caller's cast_and_await sees the success-path selector return,
  # not the underlying action's error
end
```

## Tests to update

- `test/jido/agent/agent_test.exs` — the existing "executes list of actions" test asserts both A's and B's slice fields coexist (relied on no-deep-merge plus continue-on-error). Rewrite to two cases: (a) all succeed, slice reflects last instruction; (b) middle errors, slice reflects pre-batch state.

- `test/jido/middleware/retry_test.exs` — replace `%Directive.Error{}` setup with `{:error, _}` chain return.

- Any test that asserts `cmd/2` returns `{agent, dirs}` — update to `{:ok, agent, dirs}` or `{:error, reason}` and adjust assertions.

- Any action test fixture that returns `{:ok, slice}` (two-arg) — change to `{:ok, slice, []}`.

- Action test fixtures that returned `{:ok, slice, directive}` (single, unwrapped) — wrap into a list: `{:ok, slice, [directive]}`.

## Migration guide additions

In `guides/migration.md`, append a new section:

```markdown
### Action and cmd return shapes are tagged tuples

Old:
- `run/4` returned `{:ok, slice} | {:ok, slice, directive | [directive]} | {:error, reason}`
- `cmd/2` returned `{agent, directives}` regardless of outcome
- Errors went into `dirs` as `%Directive.Error{}` and were logged

New:
- `run/4` returns `{:ok, slice, [directive]} | {:error, reason}` (always 3-tuple on success, list of directives even if empty)
- `cmd/2` returns `{:ok, agent, [directive]} | {:error, reason}`
- Multi-instruction cmd is all-or-nothing: first error aborts the batch, agent is unchanged from input, no directives execute

Recipes:

- Action that did `{:ok, %{slice | x: 1}}` becomes `{:ok, %{slice | x: 1}, []}`.
- Action that did `{:ok, slice, %Emit{...}}` becomes `{:ok, slice, [%Emit{...}]}`.
- Action that did `{:error, reason}` is unchanged.
- `cmd/2` callers that did `{agent, dirs} = MyAgent.cmd(agent, instructions)` now do `{:ok, agent, dirs} = MyAgent.cmd(agent, instructions)` and handle `{:error, reason}` explicitly.

### `cast_and_await` selectors no longer need to encode action errors

Old: selector reads slice fields the action wrote on the failure path; if you forgot to write them, the caller hung until timeout.

New: the framework delivers `{:error, reason}` directly to the caller when the chain returns an error; the selector is skipped. Write the selector to handle the success path only.

### Retry middleware now triggers on chain errors, not Error directives

If you were relying on Retry firing because an action emitted `%Directive.Error{}` for logging, that behavior is gone. Retry now fires on `{:error, _}` from the chain. To get logging-without-retry, emit the `%Error{}` from a different middleware on the success path, or use Logger directly.
```

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix test` green.
- `mix credo --strict` no new warnings.
- `mix docs` builds.
- Grep `lib/` for `%Directive.Error{` — only produced by user code or `core_next`'s routing-error branch; never produced by the cmd reducer.
- New tests cover the four cases: cmd happy path, cmd halt-on-error, ack receives error, Retry on `{:error, _}` chain return.

## Out of scope

- **`AgentServer.call/2`'s shape.** Stays `{:ok, agent} | {:error, term}`. Adding error-aware behavior to `call` is a separate decision; do it later if there's a use case `cast_and_await` doesn't cover.

- **A formal error policy** (stop-on-error, max-errors). Still deferred per task 0004 §S6. The new return shape just makes "write a 5-line middleware to stop on error" trivial — `case next.(signal, ctx) do {:error, _} -> {:ok, ctx, [%Stop{...}]} ; ok -> ok end`.

- **`subscribe_with_result/4`** or any subscriber-facing error channel. Wait for demand.

- **`Persister`'s lifecycle-signal-emit failure surface.** Already correct: emits `jido.persist.thaw.failed` / `.hibernate.failed`. Don't conflate with the request/response error path.

- **Migration of out-of-tree action fixtures.** This is a framework PR. Per [tasks/README §NO-LEGACY-ADAPTERS](README.md), no shim. External callers update to the new shape on their own.

## Risks

- **`__run_instruction__` error normalization.** The current code passes `{:error, reason}` through verbatim. Wrapping bare reasons into `%Jido.Error{}` changes what callers see. Update `Jido.Error.from_term/1` to be idempotent (passes `%Jido.Error{}` through) and add a test verifying that.

- **`fire_post_signal_hooks/3`'s new arity.** Search for all callers in `agent_server.ex` and update the call sites in lockstep. A leftover `fire_post_signal_hooks(state, signal)` call would crash at runtime.

- **`emit_through_chain` ordering.** Today: `chain → execute_directives → fire_acks → fire_subscribers`. New shape preserves the order on the success path. On the error path, `execute_directives` is skipped — which is correct (no directives), but make sure no existing logic depended on that step running unconditionally (e.g., timestamp updates).

- **Middleware that returned `{ctx, []}` (no `:ok` tag) inside libraries we depend on.** None expected in `lib/`, but search first. If found, update the middleware and any tests.

- **Retry middleware's `attempts` opt vs the old "find Error directive" behavior.** Old fixtures that emitted Error directives manually (without erroring the action) now never trigger retry. The new contract is more honest, but tests written against the old behavior will silently pass without retrying. Look for tests that asserted retry happened *N* times — make sure they're now wired against `{:error, _}` returns.

- **`AgentServer.call/2` keeping `{:ok, agent}` vs `cast_and_await` returning errors.** This intentional split must be documented. Add a sentence to `AgentServer.call/2`'s moduledoc: "Returns `{:ok, agent}` regardless of action outcome. To receive action errors, use `cast_and_await/4`."

- **Persister's interaction with the new chain return.** Persister's `on_signal` may swallow errors today (it's primarily a state-snapshot middleware). Audit: does it need to propagate `{:error, _}` from `next`, or convert to `{:ok, ctx, []}`? Default behavior should be propagate; non-lifecycle errors aren't Persister's concern.
