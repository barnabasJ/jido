defmodule JidoTest.SetStateDirective do
  @moduledoc false
  defstruct [:key, :value]
end

defimpl Jido.AgentServer.DirectiveExec, for: JidoTest.SetStateDirective do
  def exec(%{key: key, value: value}, _input_signal, state) do
    IO.puts("[SetStateDirective] setting #{key}=#{inspect(value)} during drain")
    agent = state.agent
    updated = %{agent | state: Map.put(agent.state, key, value)}
    {:ok, %{state | agent: updated}}
  end
end
