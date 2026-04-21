defmodule Jido.AgentServer.Queries do
  @moduledoc """
  Reply builders for agent-level introspection queries.

  Invoked by the `%Jido.Agent.Directive.Reply{}` executor with full
  `%Jido.AgentServer.State{}` access. Mirrors `Jido.Pod.Queries` but for
  signals that are universal to every agent (not pod-specific).

  Each function returns `{:ok, map}` on success and `{:error, term}` on
  failure; the directive maps those to `<query>.reply` and `<query>.error`
  signals respectively.
  """

  alias Jido.AgentServer.ChildInfo
  alias Jido.AgentServer.State

  @doc """
  Builder for `jido.agent.query.children`. Returns `{:ok, %{children: %{tag => pid}}}`.
  """
  @spec build_children_reply(State.t()) :: {:ok, map()}
  def build_children_reply(%State{children: children}) when is_map(children) do
    pids =
      Map.new(children, fn {tag, %ChildInfo{pid: pid}} -> {tag, pid} end)

    {:ok, %{children: pids}}
  end
end
