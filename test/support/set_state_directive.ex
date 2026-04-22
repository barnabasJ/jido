defmodule JidoTest.SetStateDirective do
  @moduledoc false
  defstruct [:key, :value]
end

defimpl Jido.AgentServer.DirectiveExec, for: JidoTest.SetStateDirective do
  def exec(%{key: key, value: value}, _input_signal, state) do
    IO.puts("[SetStateDirective] setting #{key}=#{inspect(value)} during drain")
    agent = state.agent
    # Test directive writes into the agent's :__domain__ slice (ADR 0008).
    updated = %{agent | state: put_in(agent.state, [:__domain__, key], value)}
    {:ok, %{state | agent: updated}}
  end
end
