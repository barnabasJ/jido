defmodule JidoTest.SetStateDirective do
  @moduledoc false
  defstruct [:key, :value]
end

defimpl Jido.AgentServer.DirectiveExec, for: JidoTest.SetStateDirective do
  def exec(%{key: key, value: value}, _input_signal, state) do
    agent = state.agent
    # Test directive writes into the agent's user-domain slice. This directive
    # is used with agents that declare `path: :domain` (see test_agents.ex).
    updated = %{agent | state: put_in(agent.state, [:domain, key], value)}
    {:ok, %{state | agent: updated}}
  end
end
