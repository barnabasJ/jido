defmodule Jido.Pod.Actions.QueryTopology do
  @moduledoc """
  Routed to `jido.pod.query.topology`. Builds the reply via the
  `%Jido.Agent.Directive.Reply{}` directive so topology resolution runs
  with server state access (same pattern as `Jido.Pod.Actions.QueryNodes`).

  Reply shapes:

      jido.pod.query.topology.reply → %{topology: %Jido.Pod.Topology{...}}
      jido.pod.query.topology.error → %{reason: term}
  """

  use Jido.Action, name: "pod_query_topology", schema: []

  alias Jido.Signal.Call

  @impl true
  def run(signal, _slice, _opts, _ctx) do
    directive =
      Call.reply_from_state(
        signal,
        "jido.pod.query.topology.reply",
        "jido.pod.query.topology.error",
        {Jido.Pod.Queries, :build_topology_reply, []}
      )

    {:ok, %{}, List.wrap(directive)}
  end
end
