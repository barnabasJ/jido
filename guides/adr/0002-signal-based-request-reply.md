# 0002. Request/reply over signals (`Jido.Signal.Call`)

- Status: Accepted
- Date: 2026-04-20
- Related commits: `cb47212`, `8abfce6`

## Context

The canonical way to ask an agent for information today is
`Jido.AgentServer.state/1` — a `GenServer.call` that returns the full
`%State{}` struct. The caller then digs through `state.agent.state`,
`state.children`, etc. Two problems:

- It leaks internal layout. Every caller knows about every field of
  `%State{}`. Changing the struct ripples outward.
- It forces agents to be transparent. There's no mechanism for an
  agent to say "here's the subset I want to expose for this question";
  the whole struct is always available.

The existing `Jido.AgentServer.call(server, signal)` is synchronous
signal dispatch, but it too returns the whole agent struct after
processing. Same problem, different door.

We want callers to be able to *ask a question* (send a signal) and
receive *exactly the answer they asked for* (a reply signal whose data
shape is under the agent's control).

## Decision

Introduce `Jido.Signal.Call` as a synchronous request/reply primitive
that uses the signal pipeline for both halves.

- `Jido.Signal.Call.call(server, query_signal, opts)` — client side.
  Attaches `jido_dispatch: {:pid, target: self()}` to the query (if not
  already set), casts it to the agent, blocks in a `receive` keyed on
  `query_signal.id` matched against the reply's `subject`. Timeout is
  configurable via `:timeout` option or
  `Application.get_env(:jido, :call_timeout_ms, 5_000)`.

- `Jido.Signal.Call.reply(input_signal, reply_type, data)` — action
  side helper for eager replies. Builds an `%Emit{}` directive with
  `signal.subject = input.id` and dispatch copied from the input.
  Returns `nil` when the input has no `jido_dispatch` so fire-and-
  forget casts don't accidentally emit a reply.

- Reply types separate success from error
  (`<query>.reply` vs `<query>.error`) so clients can pattern-match on
  `reply.type` instead of poking at `reply.data[:error]`.

- `cmd/2` threads the input signal into `context.signal` so actions can
  read `jido_dispatch` and `id` without us needing to shove metadata
  through the signal data field.

`AgentServer.call/2` stays as a "wait for the agent to finish
processing" sync barrier, with docs updated to point at `Signal.Call`
for anything shaped like a query.

## Consequences

- Agents decide what they expose per query — different queries produce
  different reply shapes. The caller never sees `%State{}` unless the
  reply explicitly includes it.
- Actions can now read the signal that triggered them via
  `context.signal`. Previously that context was lost at `dispatch_action`.
- `Jido.Pod.nodes/1` and `lookup_node/2` migrate to signal-based
  queries (see ADR 0003) without changing their public shape.
- Callers pay a message round-trip instead of a `GenServer.call` —
  equivalent in practice, better in traceability (both legs are
  signals flowing through the normal pipeline).
- Unique ids in `query.id` + pattern-match in `receive` means the
  caller's mailbox isn't polluted by unrelated signals even if they're
  subscribed to a shared bus.

## Alternatives considered

- **Introspection via dedicated `GenServer.call` handlers
  (`handle_call(:nodes, ...)`).** Proliferates special-case call
  handlers in AgentServer; each query is another imperative RPC. No
  uniform observability story.
- **Expose a read-only slice of `%State{}` via a sanitising
  `AgentServer.view/1`.** Agents still have to anticipate every slice
  anyone might want; doesn't compose with plugin-added fields.
- **Use the existing `AgentServer.call/2` and have the action modify
  `agent.state` with the answer.** Mixes state with reply payload;
  wrong scope.
