defmodule Jido.Agent.Strategy.Direct do
  @moduledoc """
  Default execution strategy that runs instructions immediately and sequentially.

  This strategy:
  - Executes each instruction via `Jido.Exec.run/1`
  - Merges results into agent state
  - Applies state operations (e.g., `StateOp.SetState`) to the agent
  - Returns only external directives to the caller
  - Optionally tracks instruction execution in Thread when `thread?` is enabled

  This is the default strategy and provides the simplest execution model.

  ## Thread Tracking

  When `thread?` option is enabled via `ctx[:strategy_opts][:thread?]` or if a thread
  already exists in agent state, the strategy will:
  - Ensure a Thread exists in agent state
  - Append `:instruction_start` entry before each instruction
  - Append `:instruction_end` entry after each instruction (with status :ok or :error)

  Example:
      agent = Agent.cmd(agent, MyAction, strategy_opts: [thread?: true])
  """

  use Jido.Agent.Strategy

  alias Jido.Agent
  alias Jido.Agent.Directive
  alias Jido.Agent.StateOp
  alias Jido.Observe.Config, as: ObserveConfig
  alias Jido.Agent.Strategy.InstructionTracking
  alias Jido.Agent.StateOps
  alias Jido.Error
  alias Jido.Instruction
  alias Jido.Thread.Agent, as: ThreadAgent

  @impl true
  def cmd(%Agent{} = agent, instructions, ctx) when is_list(instructions) do
    agent = maybe_ensure_thread(agent, ctx)

    {final_agent, reversed_directives} =
      Enum.reduce(instructions, {agent, []}, fn instruction, {acc_agent, acc_directives} ->
        {new_agent, new_directives} = run_instruction_with_tracking(acc_agent, instruction, ctx)
        {new_agent, Enum.reverse(new_directives) ++ acc_directives}
      end)

    {final_agent, Enum.reverse(reversed_directives)}
  end

  defp maybe_ensure_thread(agent, ctx) do
    opts = ctx[:strategy_opts] || []
    thread_enabled? = Keyword.get(opts, :thread?, false)

    if thread_enabled? or ThreadAgent.has_thread?(agent) do
      ThreadAgent.ensure(agent)
    else
      agent
    end
  end

  defp run_instruction_with_tracking(agent, %Instruction{} = instruction, ctx) do
    if ThreadAgent.has_thread?(agent) do
      agent = InstructionTracking.append_instruction_start(agent, instruction)
      {agent, directives, status} = run_instruction(agent, instruction, ctx)
      agent = InstructionTracking.append_instruction_end(agent, instruction, status)
      {agent, directives}
    else
      {agent, directives, _status} = run_instruction(agent, instruction, ctx)
      {agent, directives}
    end
  end

  defp run_instruction(agent, %Instruction{} = instruction, ctx) do
    # Reflect on the action to see whether it declared ownership of a
    # slice (Jido.Agent.ScopedAction, see ADR 0005). When it did we run
    # the action with `ctx.state` scoped to just that slice and treat
    # its return as a whole-slice replacement.
    state_key = scoped_state_key(instruction.action)
    scoped_state = scoped_state(agent.state, state_key)

    instruction =
      %{
        instruction
        | context:
            instruction.context
            |> Map.put(:state, scoped_state)
            |> Map.put(:agent, agent)
            |> Map.put(:agent_server_pid, self())
      }

    exec_opts = ObserveConfig.action_exec_opts(ctx[:jido_instance], instruction.opts)

    case Jido.Exec.run(%{instruction | opts: exec_opts}) do
      {:ok, result} when is_map(result) ->
        apply_scoped_result(agent, state_key, result, [])

      {:ok, result, effects} when is_map(result) ->
        apply_scoped_result(agent, state_key, result, List.wrap(effects))

      {:error, reason} ->
        error = Error.execution_error("Instruction failed", details: %{reason: reason})
        {agent, [%Directive.Error{error: error, context: :instruction}], :error}
    end
  end

  # Pulls state_key/0 off the action module if it's a ScopedAction.
  # Accepts bare module, {module, params}, {module, params, context}, etc —
  # Instruction.normalize has already flattened the shape into :action.
  defp scoped_state_key(mod) when is_atom(mod) and not is_nil(mod) do
    if function_exported?(mod, :state_key, 0), do: mod.state_key(), else: nil
  end

  defp scoped_state_key(_), do: nil

  defp scoped_state(agent_state, nil), do: agent_state
  defp scoped_state(agent_state, key) when is_atom(key), do: Map.get(agent_state, key, %{})

  # Unscoped action: legacy deep-merge of the returned map into full agent.state.
  defp apply_scoped_result(agent, nil, result, effects) do
    agent = StateOps.apply_result(agent, result)
    {agent, directives} = StateOps.apply_state_ops(agent, effects)
    {agent, directives, :ok}
  end

  # Scoped action: the returned map IS the new value of agent.state[state_key].
  # Wrap as a SetPath state-op so it goes through the same applied-pipeline as
  # explicit state ops (and is observable via `Jido.Agent.StateOps.apply_state_ops/2`).
  defp apply_scoped_result(agent, state_key, new_slice, effects) do
    slice_op = %StateOp.SetPath{path: [state_key], value: new_slice}
    {agent, directives} = StateOps.apply_state_ops(agent, [slice_op | effects])
    {agent, directives, :ok}
  end
end
