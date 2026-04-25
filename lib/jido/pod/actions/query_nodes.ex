defmodule Jido.Pod.Actions.QueryNodes do
  @moduledoc """
  Routed to `jido.pod.query.nodes`. Translates the query signal into a
  `%Jido.Agent.Directive.Reply{}` that — at directive execution time —
  builds the reply from the full `%AgentServer.State{}` via
  `Jido.Pod.Queries.build_nodes_reply/1`.

  The action itself never reads server-level state. It only uses the
  input signal's `id` + `jido_dispatch` (for correlation and the reply
  channel), and leaves the actual introspection to the directive
  executor — which has server state access by protocol.

  Reply shapes:

      jido.pod.query.nodes.reply → %{topology: ..., nodes: %{...}}
      jido.pod.query.nodes.error → %{reason: term}
  """

  use Jido.Action, name: "pod_query_nodes", schema: []

  alias Jido.Signal.Call

  @impl true
  def run(signal, _slice, _opts, _ctx) do
    directive =
      Call.reply_from_state(
        signal,
        "jido.pod.query.nodes.reply",
        "jido.pod.query.nodes.error",
        {Jido.Pod.Queries, :build_nodes_reply, []}
      )

    {:ok, %{}, List.wrap(directive)}
  end
end
