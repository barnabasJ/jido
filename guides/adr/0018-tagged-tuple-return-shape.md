# 0018. Tagged-tuple return shape across action / cmd / middleware

- Status: Implemented
- Implementation: Complete
- Date: 2026-04-25
- Related commits: (the ADR commit), (this implementation commit)
- Related ADRs: [0014](0014-slice-middleware-plugin.md), [0015](0015-agent-start-is-signal-driven.md), [0016](0016-agent-server-ack-and-subscribe.md), [0009 inline signal processing](0009-inline-signal-processing.md)

## Context

Post-ADRs 0014/0015/0016 (commit `99f2cdb`), the framework has three different return shapes across the action / cmd / middleware boundary, and they paper over errors in ways that bite callers:

- `action.run/4` returns `{:ok, slice} | {:ok, slice, directive | [directive]} | {:error, reason}`.
- `agent_module.cmd/2` returns `{agent, [directive]}`. On `{:error, _}` from an action, the cmd reducer turns the error into a `%Directive.Error{}` directive; the slice is left unchanged; the loop continues to the next instruction.
- Middleware `on_signal/4` returns `{ctx, [directive]}`.
- `%Directive.Error{}` is the only error channel. The `DirectiveExec` impl logs and continues.
- `fire_post_signal_hooks/2` runs ack and subscribe selectors over `agent.state`. The selector has no idea whether the action errored — it can only see slice changes.

**Two consequences bite users:**

1. **Hung waiters.** `cast_and_await` callers block until timeout when actions error, unless the user remembers to bake a `:status` / `:error` field into the slice and write it on every error path. The framework knows the action failed; it just doesn't tell anyone.

2. **Inconsistent multi-instruction batches.** `cmd(agent, [A, B, C])` runs each independently. If B errors, A's slice changes are kept, B's error becomes a logged directive, C still runs. The agent ends up partially mutated by a batch the caller asked for as a unit.

The fix is one connected change across action / cmd reducer / middleware: tagged-tuple returns end-to-end, all-or-nothing batches, and the chain's tagged result becomes the source of truth that ack delivery reads.

## Decision

### 1. Tagged-tuple return everywhere

Action, cmd reducer, and middleware all return the same shape:

```elixir
@type result(t) :: {:ok, t, [directive]} | {:error, reason}
```

| Layer | Return |
|---|---|
| `action.run(signal, slice, opts, ctx)` | `{:ok, new_slice, [directive]} \| {:error, reason}` |
| `agent_module.cmd(agent, action)` | `{:ok, new_agent, [directive]} \| {:error, reason}` |
| `next.(signal, ctx)` and `on_signal/4` | `{:ok, ctx, [directive]} \| {:error, ctx, reason}` |

Notes:

- **No `{:ok, slice}` two-arg variant.** Always include the directive list, even if empty. Removes a normalization step and a frequently-confused arity choice.
- **No `{:error, reason, [directive]}`.** If it failed, it failed — emit observability via middleware on the failure path, not from the action. Forces actions to pick a lane.
- **`reason` is wrapped into `%Jido.Error{}`** by the framework (or passed through if it already is) so consumers have a stable shape.
- **Middleware error tuple carries `ctx`.** Action errors are reported as `{:error, ctx, reason}` so middleware-staged state mutations (e.g. `Persister`'s thaw setting `ctx.agent`) commit to `state.agent` regardless of the chain outcome. Action-level rollback lives inside `cmd/2`: the input agent flows through the error tuple unchanged, so prior middleware mutations to `ctx.agent` survive.

### 2. Multi-instruction `cmd` is all-or-nothing

`cmd(agent, [A, B, C])` runs as a transaction. Reduce with `reduce_while`:

```elixir
defp __run_cmd_loop__(initial_agent, instructions, jido_instance) do
  Enum.reduce_while(instructions, {:ok, initial_agent, []}, fn
    instruction, {:ok, acc_agent, acc_dirs} ->
      case __run_instruction__(acc_agent, instruction, jido_instance) do
        {:ok, new_agent, new_dirs} ->
          {:cont, {:ok, new_agent, acc_dirs ++ List.wrap(new_dirs)}}

        {:error, _reason} = err ->
          {:halt, err}    # initial_agent stays untouched; acc_agent is discarded
      end
  end)
end
```

- First `{:error, _}` short-circuits the rest of the list.
- The original agent is returned unchanged — successful prior instructions' slice changes vanish.
- The directive list is also discarded — emits/spawns/schedules from successful priors never execute.
- Caller retry is safe: `cmd/2` is pure, so the only cost of redoing successful priors is CPU.

### 3. Ack delivery reads the chain's outcome, not the directive list

**Framing principle**: the selector is the *query* — different callers want different projections of the success-path state. The error is always the same — the action either succeeded or it didn't, and the framework owns delivery either way. This split is what lets API-layer wrappers (like `Pod.mutate/3`) ship with a default selector that handles 99% of callers, while still letting power users pass a custom selector for a different projection. Errors never need an override; selectors are tailored per use case.



`fire_post_signal_hooks/2` becomes `fire_post_signal_hooks/3`, taking `(state, signal, result)` where `result` is the tagged tuple from `chain.(signal, ctx)`:

```elixir
case result do
  {:ok, _ctx, _dirs} ->
    run pending_acks[signal.id].selector(state)   # today's path

  {:error, reason} ->
    send caller {:jido_ack, ref, {:error, reason}}
    drop entry; skip selector
end
```

- **Source of truth is the tuple, not `%Directive.Error{}`.** A user-emitted `%Error{}` for audit/log on the success path no longer accidentally short-circuits the ack.
- **Subscribers are unchanged.** They always run their selector against state. They're observers, not request/response. If a subscriber wants to react to errors, it does so through slice fields the action wrote (or a future `subscribe_with_result/4` — defer until there's demand).
- **`AgentServer.call/2` stays as-is.** Continues to return `{:ok, agent}` even when the chain returned `{:error, _}` — keep the blast radius small. `cast_and_await` is the error-aware variant. Document it.

### 4. No `ctx[:__signal_result__]`, no per-signal-id stash

Earlier sketches threaded the result via a magic ctx key or a `state.signal_results[signal.id]` map. Both are unnecessary:

- [ADR 0009](0009-inline-signal-processing.md) pinned that signals process inline — exactly one in flight at any time. There's no concurrent collision to disambiguate; keying by `signal.id` is over-engineering.
- The chain's tagged tuple already carries the outcome. `emit_through_chain` reads it from `chain.(signal, ctx)` as a local; never touches state or ctx for it.
- No `__xxx__` magic keys — we just spent task 0002 deleting those from slice paths; don't reintroduce them.

### 5. Retry middleware simplifies

Today: scans `dirs` for `%Directive.Error{}`. After: pattern-matches the chain return.

```elixir
def on_signal(signal, ctx, opts, next) do
  case next.(signal, ctx) do
    {:error, _ctx, _reason} when attempts_left > 1 ->
      attempt(signal, ctx, next, attempts_left - 1)

    other ->
      other
  end
end
```

More honest about what Retry actually means ("retry on action failure"), not what it observed ("happened to find an Error directive in the dirs"). Won't fire spuriously when a user emits an `%Error{}` for logging on the success path. Note the 3-tuple match: `next.(signal, ctx)` returns `{:error, ctx, reason}` so middleware-staged state mutations propagate even on retry — see §1.

### 6. Persister IO errors stay scoped to lifecycle signals

Persister middleware raises/returns errors only on `jido.agent.lifecycle.starting` and `.stopping`. No `cast_and_await` caller is waiting on those signals, so the new ack-error path doesn't apply. The existing `jido.persist.thaw.failed` / `.hibernate.failed` emit signals are the right surface for those failures.

### 7. `%Directive.Error{}` keeps its current role: observability + log

It's still produced for:

- User code that explicitly returns one (audit middleware, manual emit)
- The cmd reducer no longer manufactures one — the action's `{:error, _}` propagates through the tagged tuple instead.
- Routing failures inside `core_next` still produce one for the log path; whether they ALSO short-circuit the ack is the same as the action-error case via `{:error, %RoutingError{}}` from `next`.

The `DirectiveExec` impl is unchanged: `Logger.error(...)`, return `{:ok, state}`. It's a strict log channel now.

## Consequences

- **`cast_and_await` becomes useful by default.** Callers no longer need to teach the action to write a `:status: :failed` field into a slice path the selector knows about. Errors arrive automatically. The selector is reduced to its essential job: extract the success-path payload.

- **Multi-instruction batches are atomic from the caller's perspective.** A `cmd(agent, [A, B, C])` either updates the agent fully or not at all. Partial mutations are no longer a debugging trap.

- **Action authors lose a "report and continue" idiom.** Today, an action could return `{:ok, slice, [%Error{...}]}` to log a non-fatal issue. After: that's still legal (the success-path directive list can include an Error directive for logging), but the action can no longer simultaneously report success-with-failure. Pick a lane: either it succeeded (return `:ok`) or it didn't (return `{:error, _}`).

- **Middleware authors gain pattern-match clarity.** Retry, error logging, and "stop on error" middleware all become 5-line one-liners over the tagged tuple. The framework no longer has a hidden "scan directives for Error" idiom.

- **Migration cost is real but mechanical.** Every action's `run/4` clause that returns `{:ok, slice}` becomes `{:ok, slice, []}`. Every `cmd/2` callsite that destructured `{agent, dirs}` becomes `{:ok, agent, dirs}` (or matches the error). Tests follow the same recipe. Search-and-replace covers most of it.

- **`AgentServer.call/2` and the subscribe-side primitives are intentionally unchanged.** This ADR moves only the request-side contract. If we later want subscribers to see error returns, that's a separate, additive primitive — not a change to existing semantics.

- **`Jido.Error` becomes the canonical wrapper.** Bare-atom errors like `{:error, :not_found}` are framed into `%Jido.Error{}` at the action/middleware boundary, so consumers can do `case err do %Jido.Error{kind: :not_found} -> ...`. Already-wrapped errors pass through.

## Alternatives considered

**Keep `{:ok, slice}` two-arg success variant.** Smaller migration. Rejected: every action-author has to remember which arity to use, and the framework has to normalize. The cost of *always* writing `{:ok, slice, []}` is one keystroke per action; the cost of supporting both is permanent ambiguity.

**Allow `{:error, reason, [directive]}`.** Lets actions report partial work alongside an error. Rejected: it's the same "report and continue" idiom this ADR is removing. If you need to emit observability on the failure path, do it in middleware that pattern-matches `{:error, _, _}` from the chain return.

**Have middleware error tuple be `{:error, reason}` (no ctx).** Symmetric with action / cmd. Rejected: state-bearing middleware (`Persister` thaws and stages `ctx.agent`) needs its mutations to commit even when a downstream layer errors. With a 2-tuple error, `run_chain` cannot distinguish "I want to commit middleware mutations but report an action error" from "rollback everything," and would have to take one or the other — neither is right. The 3-tuple `{:error, ctx, reason}` lets `run_chain` commit `ctx.agent` to `state.agent` unconditionally, with action-level rollback handled inside `cmd/2` (the input agent flows through unchanged on error, so prior middleware mutations to `ctx.agent` survive).

**Continue propagating errors via `%Directive.Error{}`.** Smaller-blast-radius change: only fix `cast_and_await` to detect Error directives in the result, leave action contracts alone. Rejected: the directive list is the wrong place. Any user who emits `%Error{}` for logging on the success path would accidentally short-circuit the ack. The chain's outcome is fundamentally a different question than "what did the action ask the framework to do next."

**Stash result on `ctx[:__signal_result__]` or `state.signal_results[signal.id]`.** Lets the existing post-hook signature (state-only) stay unchanged. Rejected: introduces a new magic key (just deleted those in task 0002), or a per-signal-id map (over-engineered for inline-processed signals per [ADR 0009](0009-inline-signal-processing.md)). The chain's tagged tuple already carries the outcome — pass it as an argument.

**Make `cmd/2` continue past errors but return both kept changes and the error.** Like JavaScript's `Promise.allSettled`. Rejected: agents are stateful and ordered — partial application of a batch leaves them in shapes that would never have arisen from any sequence of valid `cmd` calls. All-or-nothing matches user expectations of a transactional batch.

**Subscribe-side error channel** (`subscribe_with_result/4` that fires on errors too). Rejected for now: subscribers are observers; the request/response semantics belong on `cast_and_await`. If a future caller pattern needs error fan-out, add the primitive then. No demand today, low cost to defer.
