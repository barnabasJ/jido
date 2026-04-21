defmodule Jido.Agent.Directive.Reply do
  @moduledoc """
  Directive that builds a reply signal from the full `%AgentServer.State{}`
  at execution time and dispatches it to the caller of a
  `Jido.Signal.Call.call/3` request.

  ## Why this is a directive, not an action

  Actions run with a sandboxed context (`agent.state`, the agent struct,
  the input signal) — they deliberately do not see server-level
  internals like `state.children`, `state.jido`, or `state.registry`.
  That's the right shape for domain logic, but it's the wrong shape for
  introspection queries that *must* read server state to answer
  correctly (e.g. "which of my nodes is running right now?").

  Directive executors receive the full `%AgentServer.State{}` as a
  documented part of the `DirectiveExec` protocol. So we push query
  resolution through a directive: the action's job is only to translate
  "a query signal came in" into "emit a Reply directive"; the
  directive's executor then reads whatever state it needs and produces
  the reply.

  ## Fields

  * `input_signal` — the query signal (carries `id` for correlation and
    `jido_dispatch` for the reply channel).
  * `reply_type` — signal type for a successful reply.
  * `error_type` — signal type when `build` returns `{:error, _}`.
  * `build` — `{module, fun, extra_args}`. Runtime calls
    `apply(module, fun, [%AgentServer.State{} | extra_args])` and
    expects `{:ok, map}` or `{:error, term}`.

  ## Example

      %Reply{
        input_signal: sig,
        reply_type: "jido.pod.query.nodes.reply",
        error_type: "jido.pod.query.nodes.error",
        build: {Jido.Pod.Queries, :build_nodes_reply, []}
      }

  `Jido.Signal.Call.reply_from_state/4` is the recommended builder.
  """

  @enforce_keys [:input_signal, :reply_type, :error_type, :build]
  defstruct [:input_signal, :reply_type, :error_type, :build]

  @type builder ::
          {module :: module(), fun :: atom(), extra_args :: [term()]}

  @type t :: %__MODULE__{
          input_signal: Jido.Signal.t(),
          reply_type: String.t(),
          error_type: String.t(),
          build: builder()
        }
end
