# 0003. Server-state access lives in directives, not actions

- Status: Accepted
- Implementation: Complete
- Date: 2026-04-20
- Related commits: `0df476f`

## Context

When implementing signal-based pod introspection (ADR 0002), the first
cut had the `QueryNodes` action call `Jido.Pod.Runtime.build_node_snapshots/2`
— but that function needs fields that only live on `%Jido.AgentServer.State{}`:
`state.children`, `state.jido`, `state.partition`, `state.registry`,
`state.id`, `state.agent_module`. Actions' contexts only carry agent
state (`ctx.state`), the agent struct, and the input signal.

We briefly threaded the whole `%State{}` into action context as
`ctx.server_state`. It worked but had a structural problem: actions
are the *sandboxed* layer of the runtime. They compute effects from
agent state; they're deliberately not supposed to see the signal queue,
the children map, the lifecycle state, or the debug events. Handing
them `%State{}` contradicted the whole reason that layer is sandboxed.

The directive-exec protocol already receives the full `%State{}` as a
documented input:

    @spec exec(struct(), Signal.t(), Jido.AgentServer.State.t()) ::
            {:ok, State.t()} | {:async, ref, State.t()} | {:stop, reason, State.t()}

So the right layer for "read server-level state to answer a query"
was always sitting there.

## Decision

Query resolution that needs `%State{}` belongs in a directive. Actions
translate the query signal into a directive; the directive's executor
reads whatever it needs from `%State{}` and dispatches the reply.

- New `%Jido.Agent.Directive.Reply{}` carries `input_signal`,
  `reply_type`, `error_type`, and `build: {module, fun, extra_args}`.
  Its `DirectiveExec` impl calls `apply(module, fun, [state | extra_args])`,
  builds a signal with `subject: input.id`, and dispatches it via the
  input's `jido_dispatch`.

- `Jido.Signal.Call.reply_from_state/4` constructs the directive from
  an action. Returns `nil` when the input lacks `jido_dispatch` so
  fire-and-forget casts don't accidentally reply.

- `Jido.Pod.Queries` collects the builder functions
  (`build_nodes_reply/1`, `build_topology_reply/1`). They take
  `%State{}` and return `{:ok, map} | {:error, term}`.

- `Jido.Pod.Actions.QueryNodes` and `QueryTopology` are now ~10 lines
  each: read the input signal from context, return a `%Reply{}`
  directive. No server-state reads, no `try/rescue`, no infra handles.

- The `__server_state__` plumbing in `cmd/2` and
  `AgentServer.dispatch_action/5` is reverted. `ctx.server_state` no
  longer exists. Actions see: `state` (agent state), `agent`,
  `agent_server_pid`, `signal`.

## Consequences

- The action layer stays sandboxed. New queries that need server
  state follow the same pattern (builder fn + `%Reply{}` directive) —
  there's no temptation to reach into `%State{}` from action code
  because the infrastructure isn't threaded through.
- Query work runs at directive-exec time, slightly later in the
  pipeline than action run. For introspection that's fine; the reply
  arrives asynchronously regardless.
- Builder functions are `{module, fun, args}` tuples so they're
  serialisable in principle (we don't persist directives today, but
  nothing in this design blocks it).
- `build_node_snapshots/2` in `Pod.Runtime` stays public as the
  shared helper — ADR 0001 exposed it; builder functions reuse it.

## Alternatives considered

- **Mirror running pids into the pod plugin's agent-state slice
  (`agent.state[:__pod__][:running_pids]`)**, updated from
  `jido.agent.child.started` / `jido.agent.child.exit` signal routes.
  Then build_node_snapshots runs purely from agent state and no
  server access is needed. Correct long-term design, but touches
  plugin checkpoint/restore and persistence. Filed as future work;
  for now the directive approach gives us the right *layering*
  without the plumbing cost.
- **Keep `ctx.server_state` but narrow it to a scoped refs map**
  (`%{jido, partition, registry, id, agent_module}`). Less leaky than
  full `%State{}`, more leaky than nothing. Felt like an incomplete
  compromise — either actions own this concern or they don't.
- **Have the pod handle introspection via dedicated `handle_call`
  clauses instead of signal_routes.** Reintroduces the
  `AgentServer.state` anti-pattern that ADR 0002 set out to eliminate.
