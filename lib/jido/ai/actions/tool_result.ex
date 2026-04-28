defmodule Jido.AI.Actions.ToolResult do
  @moduledoc """
  Handles `"ai.react.tool.completed"` — one tool call just finished.

  Each `Jido.AI.Directive.ToolExec` produces one of these signals. The
  action appends the result message to `:context` and accumulates the
  result in `:tool_results_received`. When the count matches the
  `:pending_tool_calls` batch, the in-flight batch is complete: the
  action runs cycle detection (comparing the just-finished batch's
  signature against `:previous_tool_signature`), prepends the cycle
  warning to the context if they match, updates the signature, clears
  the batch bookkeeping, and emits the next `Jido.AI.Directive.LLMCall`.

  Stale signals (`request_id` mismatch) and signals received after the
  slice has already terminated are dropped.

  ADR 0019: pure state mutation + directive emission. No I/O.
  """

  use Jido.Action,
    name: "ai_tool_result",
    path: :ai,
    description: "Process one tool result and fan-in to the next LLM turn.",
    schema: [
      tool_call_id: [type: :string, required: true],
      name: [type: :string, required: true],
      content: [type: :string, required: true],
      request_id: [type: :string, required: true]
    ]

  alias Jido.AI.Directive.LLMCall
  alias Jido.AI.ReAct
  alias ReqLLM.Context

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    cond do
      stale?(slice, data.request_id) -> {:ok, slice, []}
      slice.status != :running -> {:ok, slice, []}
      true -> append_and_maybe_dispatch(data, slice)
    end
  end

  defp stale?(%{request_id: current}, request_id), do: current != request_id

  defp append_and_maybe_dispatch(data, slice) do
    msg = Context.tool_result(data.tool_call_id, data.name, data.content)
    new_context = Context.append(slice.context, msg)

    received =
      slice.tool_results_received ++
        [%{tool_call_id: data.tool_call_id, name: data.name, content: data.content}]

    if length(received) == length(slice.pending_tool_calls) do
      finalize_batch(slice, new_context)
    else
      {:ok, %{slice | context: new_context, tool_results_received: received}, []}
    end
  end

  defp finalize_batch(slice, new_context) do
    current_signature = ReAct.tool_call_signature(slice.pending_tool_calls)

    {warned_context, _} =
      maybe_append_cycle_warning(new_context, slice.previous_tool_signature, current_signature)

    new_slice = %{
      slice
      | context: warned_context,
        pending_tool_calls: [],
        tool_results_received: [],
        previous_tool_signature: current_signature
    }

    directive = %LLMCall{
      model: slice.model,
      context: warned_context,
      tools: slice.tools,
      request_id: slice.request_id,
      llm_opts: slice.llm_opts
    }

    {:ok, new_slice, [directive]}
  end

  defp maybe_append_cycle_warning(context, previous_signature, current_signature)
       when is_binary(previous_signature) and previous_signature == current_signature do
    {Context.append(context, Context.user(ReAct.cycle_warning())), :warned}
  end

  defp maybe_append_cycle_warning(context, _previous, _current), do: {context, :no_warning}
end
