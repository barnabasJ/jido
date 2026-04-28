defmodule Jido.AI.Actions.Ask do
  @moduledoc """
  Handles `"ai.react.ask"` — opens a ReAct run.

  Refuses concurrent runs (`{:error, :busy}` when `slice.status == :running`,
  per ADR 0022 §5), otherwise seeds the slice with a fresh
  `ReqLLM.Context`, transitions to `:running`, stores the run config
  (model / tools / llm_opts) so subsequent `LLMCall` directives in the
  same run can reuse it, and emits the first `Jido.AI.Directive.LLMCall`
  to start the conversation.

  ADR 0019: this action only mutates state and emits a directive — the
  blocking ReqLLM call lives in the directive's executor.
  """

  use Jido.Action,
    name: "ai_ask",
    path: :ai,
    description: "Open a ReAct run on a Jido.AI.Agent.",
    schema: [
      query: [type: :string, required: true],
      request_id: [type: :string, required: true],
      model: [type: :any, required: true],
      tools: [type: {:list, :atom}, default: []],
      system_prompt: [type: {:or, [:string, nil]}, default: nil],
      max_iterations: [type: :pos_integer, default: 10],
      llm_opts: [type: :keyword_list, default: []]
    ]

  alias Jido.AI.Directive.LLMCall
  alias ReqLLM.Context

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    if running?(slice) do
      {:error, :busy}
    else
      context = build_initial_context(data.query, data.system_prompt)

      new_slice = %{
        status: :running,
        request_id: data.request_id,
        context: context,
        iteration: 0,
        max_iterations: data.max_iterations,
        result: nil,
        error: nil,
        pending_tool_calls: [],
        tool_results_received: [],
        previous_tool_signature: nil,
        model: data.model,
        tools: data.tools,
        llm_opts: data.llm_opts
      }

      directive = %LLMCall{
        model: data.model,
        context: context,
        tools: data.tools,
        request_id: data.request_id,
        llm_opts: data.llm_opts
      }

      {:ok, new_slice, [directive]}
    end
  end

  defp running?(%{status: :running}), do: true
  defp running?(_), do: false

  defp build_initial_context(query, nil), do: Context.new([Context.user(query)])

  defp build_initial_context(query, system) when is_binary(system) do
    Context.new([Context.system(system), Context.user(query)])
  end
end
