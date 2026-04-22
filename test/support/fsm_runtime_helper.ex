defmodule JidoTest.Support.FSMRuntimeHelper do
  @moduledoc false

  alias Jido.Agent.Directive
  alias Jido.Observe.Config, as: ObserveConfig

  @doc false
  @spec run_cmd(module(), struct(), term()) :: {struct(), [struct()]}
  def run_cmd(agent_module, agent, action) do
    {agent, directives} = agent_module.cmd(agent, action)
    run_directives(agent_module, agent, directives)
  end

  @doc """
  Drains any `RunInstruction` directives emitted by a strategy's cmd/2 —
  runs the instruction, feeds the normalized result back through
  `agent_module.cmd(agent, {result_action, payload})` — and collects
  any non-`RunInstruction` directives returned along the way.

  The helper exists so tests can verify the externally-visible directives
  produced by a strategy (Emit / Error / Stop / etc.) after the runtime's
  RunInstruction plumbing has settled, without booting a full AgentServer.
  """
  @spec run_directives(module(), struct(), [struct()]) :: {struct(), [struct()]}
  def run_directives(agent_module, agent, directives) when is_list(directives) do
    do_run(agent_module, agent, directives, [])
  end

  defp do_run(_agent_module, agent, [], buffered), do: {agent, Enum.reverse(buffered)}

  defp do_run(agent_module, agent, [directive | rest], buffered) do
    case directive do
      %Directive.RunInstruction{
        instruction: instruction,
        result_action: result_action,
        meta: meta
      } ->
        payload = execute_instruction(instruction, agent, meta)

        {agent, more_directives} =
          agent_module.cmd(agent, {result_action, payload})

        do_run(agent_module, agent, List.wrap(more_directives) ++ rest, buffered)

      other ->
        do_run(agent_module, agent, rest, [other | buffered])
    end
  end

  defp execute_instruction(instruction, agent, meta) do
    enriched = %{
      instruction
      | context: Map.put(instruction.context || %{}, :state, agent.state)
    }

    exec_opts = ObserveConfig.action_exec_opts(nil, enriched.opts)

    %{enriched | opts: exec_opts}
    |> Jido.Exec.run()
    |> normalize_result_payload()
    |> Map.put(:instruction, instruction)
    |> Map.put(:meta, meta || %{})
  end

  defp normalize_result_payload({:ok, result}),
    do: %{status: :ok, result: result, effects: []}

  defp normalize_result_payload({:ok, result, effects}),
    do: %{status: :ok, result: result, effects: List.wrap(effects)}

  defp normalize_result_payload({:error, reason}),
    do: %{status: :error, reason: reason, effects: []}

  defp normalize_result_payload({:error, reason, effects}),
    do: %{status: :error, reason: reason, effects: List.wrap(effects)}
end
