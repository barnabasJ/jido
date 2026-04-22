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
    # Every agent has a slice (ADR 0007). We run the action with `ctx.state`
    # scoped to just that slice. How the action's return is applied depends on
    # whether the action is a ScopedAction or not:
    #   - ScopedAction: return is the new value of the slice (wholesale replace)
    #   - regular Action: return is deep-merged into the slice (so partial
    #     updates like `{:ok, %{counter: n + 1}}` preserve other keys)
    {state_key, scoped?} = resolve_state_key(agent, instruction.action)
    scoped_state = Map.get(agent.state, state_key, %{})

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
        apply_slice_result(agent, state_key, scoped?, result, [])

      {:ok, result, effects} when is_map(result) ->
        apply_slice_result(agent, state_key, scoped?, result, List.wrap(effects))

      {:error, reason} ->
        error = Error.execution_error("Instruction failed", details: %{reason: reason})
        {agent, [%Directive.Error{error: error, context: :instruction}], :error}
    end
  end

  # Resolve `{state_key, scoped?}`:
  #   - If the action module exports `state_key/0` (i.e. it's a ScopedAction),
  #     use its declared slice and mark scoped? = true.
  #   - Otherwise, fall back to the agent's own slice key; scoped? = false so
  #     the runtime uses deep-merge semantics for partial-update returns.
  defp resolve_state_key(%Agent{agent_module: mod}, action)
       when is_atom(action) and not is_nil(action) do
    if function_exported?(action, :state_key, 0) do
      {action.state_key(), true}
    else
      {mod.state_key(), false}
    end
  end

  defp resolve_state_key(%Agent{agent_module: mod}, _action), do: {mod.state_key(), false}

  # Scoped action: the returned map IS the new value of the slice.
  defp apply_slice_result(agent, state_key, true, new_slice, effects) do
    slice_op = %StateOp.SetPath{path: [state_key], value: new_slice}
    {agent, directives} = StateOps.apply_state_ops(agent, [slice_op | effects])
    {agent, directives, :ok}
  end

  # Non-scoped action: deep-merge returned map into existing slice contents.
  # This preserves the pre-ADR-0007 ergonomics where an action returning
  # `%{counter: n + 1}` updates only `:counter` and leaves other slice keys alone.
  defp apply_slice_result(agent, state_key, false, partial, effects) do
    current_slice = Map.get(agent.state, state_key, %{})
    merged_slice = DeepMerge.deep_merge(current_slice, partial)
    slice_op = %StateOp.SetPath{path: [state_key], value: merged_slice}
    {agent, directives} = StateOps.apply_state_ops(agent, [slice_op | effects])
    {agent, directives, :ok}
  end
end
