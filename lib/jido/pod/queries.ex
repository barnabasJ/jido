defmodule Jido.Pod.Queries do
  @moduledoc """
  Reply builders for pod introspection queries.

  These functions are invoked by the `%Jido.Agent.Directive.Reply{}`
  executor and run with full `%Jido.AgentServer.State{}` access — so they
  can resolve running pids, parent bindings, and anything else that
  lives server-side.

  Each function returns `{:ok, map}` or `{:error, term}`; the directive
  maps success to the `reply_type` of the query (e.g.
  `jido.pod.query.nodes.reply`) and errors to the `error_type`.
  """

  alias Jido.AgentServer.State
  alias Jido.Pod.Runtime
  alias Jido.Pod.TopologyState

  @doc "Builds the reply body for `jido.pod.query.nodes`."
  @spec build_nodes_reply(State.t()) :: {:ok, map()} | {:error, term()}
  def build_nodes_reply(%State{} = state) do
    with {:ok, topology} <- TopologyState.fetch_topology(state) do
      {:ok, %{topology: topology, nodes: Runtime.build_node_snapshots(state, topology)}}
    end
  end

  @doc "Builds the reply body for `jido.pod.query.topology`."
  @spec build_topology_reply(State.t()) :: {:ok, map()} | {:error, term()}
  def build_topology_reply(%State{} = state) do
    case TopologyState.fetch_topology(state) do
      {:ok, topology} -> {:ok, %{topology: topology}}
      {:error, _} = err -> err
    end
  end
end
