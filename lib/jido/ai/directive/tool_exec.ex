defmodule Jido.AI.Directive.ToolExec do
  @moduledoc """
  Side-effect directive: runs one tool call.

  Emitted by `Jido.AI.Actions.LLMTurn`, one per tool call in a turn that
  asked for tools. The executor spawns a Task that resolves the tool by
  name, coerces arguments through the action's schema, runs the action
  via `Jido.Exec.run/4`, and casts back an `"ai.react.tool.completed"`
  signal carrying a JSON-encoded result.

  Tool errors and crashes are caught and converted to error JSON inside
  the same `tool.completed` envelope — tool failures are conversational
  data, not run failures, so the LLM can read the error and recover. A
  tool failure never produces an `"ai.react.failed"` signal.
  """

  @type t :: %__MODULE__{
          tool_call: %{id: String.t(), name: String.t(), arguments: map()},
          tool_modules: [module()],
          request_id: String.t()
        }

  @enforce_keys [:tool_call, :request_id]
  defstruct tool_call: nil,
            tool_modules: [],
            request_id: nil
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.AI.Directive.ToolExec do
  @moduledoc false

  alias Jido.Action.Tool, as: ActionTool
  alias Jido.AgentServer
  alias Jido.AI.Directive.ToolExec
  alias Jido.AI.ToolAdapter
  alias Jido.Signal

  @impl true
  def exec(%ToolExec{} = directive, _input_signal, state) do
    agent_pid = self()
    task_sup = Jido.task_supervisor_name(state.jido)
    source = "/agent/#{state.id}"

    {:ok, _pid} =
      Task.Supervisor.start_child(task_sup, fn ->
        run_and_dispatch(directive, agent_pid, source)
      end)

    :ok
  end

  defp run_and_dispatch(%ToolExec{} = d, agent_pid, source) do
    content = run_tool(d.tool_call, d.tool_modules)

    data = %{
      tool_call_id: d.tool_call.id,
      name: d.tool_call.name,
      content: content,
      request_id: d.request_id
    }

    signal = Signal.new!("ai.react.tool.completed", data, source: source)
    _ = AgentServer.cast(agent_pid, signal)
  end

  defp run_tool(%{name: name, arguments: args}, modules) do
    case ToolAdapter.lookup_action(name, modules) do
      {:ok, module} -> safe_invoke(module, args, name)
      {:error, :not_found} -> Jason.encode!(%{error: "tool not found: #{name}"})
    end
  end

  defp safe_invoke(module, args, name) do
    params = ActionTool.convert_params_using_schema(args, module.schema())

    case Jido.Exec.run(module, params, %{}, []) do
      {:ok, result, _directives} -> Jason.encode!(result)
      {:error, reason} -> Jason.encode!(%{error: format_error(reason)})
    end
  rescue
    exception ->
      Jason.encode!(%{error: "#{name} crashed: #{Exception.message(exception)}"})
  catch
    kind, reason ->
      Jason.encode!(%{error: "#{name} #{kind}: #{inspect(reason)}"})
  end

  defp format_error(%_{} = err) when is_exception(err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
