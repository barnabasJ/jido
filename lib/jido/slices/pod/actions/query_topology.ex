defmodule Jido.Slices.Pod.Actions.QueryTopology do
  @moduledoc """
  Routed to `jido.pod.query.topology`. Builds the reply via the
  `%Jido.Directives.Reply{}` directive so topology resolution runs
  with server state access (same pattern as `Jido.Slices.Pod.Actions.QueryNodes`).

  Reply shapes:

      jido.pod.query.topology.reply → %{topology: %Jido.Slices.Pod.Topology{...}}
      jido.pod.query.topology.error → %{reason: term}
  """

  use Jido.Action

  action do
    name "pod_query_topology"
    schema []
  end

  alias Jido.Signal.Call

  @impl true
  def run(signal, slice, _opts, _ctx) do
    directive =
      Call.reply_from_state(
        signal,
        "jido.pod.query.topology.reply",
        "jido.pod.query.topology.error",
        {Jido.Slices.Pod.Queries, :build_topology_reply, []}
      )

    # Read-only query: return the unchanged slice so the framework's
    # slice-result handler doesn't overwrite agent.state[:pod] with `%{}`.
    {:ok, slice, List.wrap(directive)}
  end
end
