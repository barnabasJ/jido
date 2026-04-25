defmodule Jido.AgentServer.Actions.QueryChildren do
  @moduledoc """
  Routed to `jido.agent.query.children`. Builds the reply via the
  `%Jido.Agent.Directive.Reply{}` directive so the children map is read
  under directive execution with server state access.

  Reply shapes:

      jido.agent.query.children.reply → %{children: %{tag => pid}}
      jido.agent.query.children.error → %{reason: term}
  """

  use Jido.Action, name: "agent_query_children", schema: []

  alias Jido.Signal.Call

  @impl true
  def run(signal, _slice, _opts, _ctx) do
    directive =
      Call.reply_from_state(
        signal,
        "jido.agent.query.children.reply",
        "jido.agent.query.children.error",
        {Jido.AgentServer.Queries, :build_children_reply, []}
      )

    {:ok, %{}, List.wrap(directive)}
  end
end
