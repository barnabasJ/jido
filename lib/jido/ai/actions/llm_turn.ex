defmodule Jido.AI.Actions.LLMTurn do
  @moduledoc """
  Handles `"ai.react.llm.completed"` — one LLM turn just finished.

  Drops stale signals (different `request_id`) and signals received after
  the slice has already terminated. For live signals, decides what
  happens next:

    * `final_answer` turn → append the assistant message to the context
      and settle the slice as `:completed`, recording the text in
      `:result`.
    * `tool_calls` turn → append the assistant message (with tool calls)
      to the context, store the calls in `:pending_tool_calls`, and emit
      one `Jido.AI.Directive.ToolExec` per call. If continuing would
      exceed `:max_iterations` the slice is settled as `:completed`
      *without* tool execution — the run is truncated.

  The `:iteration` counter is incremented when each LLM turn lands here,
  so it tracks the number of LLM calls *completed*. Cycle detection is
  the responsibility of `Jido.AI.Actions.ToolResult` — this action only
  records the in-flight batch in `:pending_tool_calls`; the comparison
  to `:previous_tool_signature` happens at the boundary where the *next*
  LLMCall fires.

  ADR 0019: pure state mutation + directive emission. No I/O.
  """

  use Jido.Action,
    name: "ai_llm_turn",
    path: :ai,
    description: "Process a completed LLM turn and decide the next ReAct step.",
    schema: [
      turn: [type: :any, required: true],
      request_id: [type: :string, required: true]
    ]

  alias Jido.AI.Directive.ToolExec
  alias Jido.AI.Turn
  alias ReqLLM.Context

  @impl true
  def run(%Jido.Signal{data: %{turn: turn, request_id: request_id}}, slice, _opts, _ctx) do
    cond do
      stale?(slice, request_id) -> {:ok, slice, []}
      slice.status != :running -> {:ok, slice, []}
      true -> handle_turn(turn, slice)
    end
  end

  defp stale?(%{request_id: current}, request_id), do: current != request_id

  defp handle_turn(%Turn{type: :final_answer, text: text}, slice) do
    new_context = Context.append(slice.context, Context.assistant(text || ""))

    new_slice = %{
      slice
      | iteration: slice.iteration + 1,
        context: new_context,
        status: :completed,
        result: text
    }

    {:ok, new_slice, []}
  end

  defp handle_turn(%Turn{type: :tool_calls, tool_calls: tool_calls, text: text}, slice) do
    iteration = slice.iteration + 1

    msg_calls =
      Enum.map(tool_calls, fn tc ->
        %{id: tc.id, name: tc.name, arguments: tc.arguments}
      end)

    assistant_msg = Context.assistant(text || "", tool_calls: msg_calls)
    new_context = Context.append(slice.context, assistant_msg)

    if iteration >= slice.max_iterations do
      truncate(slice, new_context, iteration)
    else
      dispatch_tools(slice, new_context, iteration, msg_calls)
    end
  end

  defp truncate(slice, new_context, iteration) do
    new_slice = %{
      slice
      | iteration: iteration,
        context: new_context,
        status: :completed,
        result: nil
    }

    {:ok, new_slice, []}
  end

  defp dispatch_tools(slice, new_context, iteration, msg_calls) do
    new_slice = %{
      slice
      | iteration: iteration,
        context: new_context,
        pending_tool_calls: msg_calls,
        tool_results_received: []
    }

    directives =
      Enum.map(msg_calls, fn call ->
        %ToolExec{
          tool_call: call,
          tool_modules: slice.tools,
          request_id: slice.request_id
        }
      end)

    {:ok, new_slice, directives}
  end
end
