defmodule Jido.AI.ReAct do
  @moduledoc """
  ReAct strategy as a configured `Jido.Slice`.

  Attached to any `Jido.Agent` via the framework's `slices:` option:

      defmodule MyApp.SupportAgent do
        use Jido.Agent,
          name: "support",
          slices: [
            {Jido.AI.ReAct,
              model: "anthropic:claude-haiku-4-5-20251001",
              tools: [MyApp.Actions.LookupOrder, MyApp.Actions.RefundOrder],
              system_prompt: "You are a support agent.",
              max_iterations: 5}
          ]
      end

  The slice owns the `:ai` key of the agent's state and contains the full
  lifecycle of one ReAct conversation.

  ## State machine

      :idle ──ask──▶ :running ─┬─final answer──▶ :completed
                               ├─tool calls + iter < max ─▶ :running (next iter)
                               ├─tool calls + iter ≥ max ─▶ :completed (truncated)
                               └─LLM error ──▶ :failed

  Concurrent `ai.react.ask` while `:running` is rejected with
  `{:error, :busy}` (ADR 0022 §5).

  ## Slice fields

    * `:status` — `:idle | :running | :completed | :failed`.
    * `:request_id` — opaque correlation id minted by `Jido.AI.ask/3`.
      Every response signal carries it; mismatched signals are dropped as
      stale.
    * `:context` — the full `ReqLLM.Context` carried verbatim per ADR
      0022 §3 — system + user + assistant + tool messages.
    * `:iteration` — number of LLM calls completed so far.
    * `:max_iterations` — cap on LLM calls; further `:tool_calls` turns
      after this is reached truncate the run as `:completed`.
    * `:result` — final answer text on `:completed`, or `nil`.
    * `:error` — error term on `:failed`, or `nil`.
    * `:pending_tool_calls` — tool calls from the last `:tool_calls` turn,
      kept until every paired tool result has come back.
    * `:tool_results_received` — tool results accumulated for the in-flight
      tool batch; cleared when the batch completes and the next LLMCall
      fires.
    * `:previous_tool_signature` — signature of the last batch's tool
      calls; used to detect tool-call cycles and prepend a cycle-warning
      user message before the next LLMCall.
    * `:model`, `:tools`, `:system_prompt`, `:llm_opts` — run config
      seeded from the slice's `slices:` config (validated through
      `config_schema/0`); `Jido.AI.Actions.Ask` falls back to these
      values when the opening signal omits them.

  ## Config keys (`config_schema/0`)

    * `:model` — any value accepted by `ReqLLM.Generation.generate_text/3`.
      Optional; the floor enforced by the `Ask` action is `{:error, :no_model}`
      when neither the slice config nor the per-call `Jido.AI.ask/3` opts
      supply a model.
    * `:tools` — list of `Jido.Action` modules exposed to the model.
    * `:system_prompt` — system message text prepended to the conversation.
    * `:max_iterations` — cap on LLM calls per run (default 10).
    * `:max_tokens` — folded into `:llm_opts` (default 4096).
    * `:temperature` — folded into `:llm_opts` (default 0.2).
    * `:llm_opts` — extra keyword list merged into per-call options
      (last-write-wins over `:max_tokens` / `:temperature`).
  """

  alias Jido.AI.Actions

  @cycle_warning "You already called the same tool(s) with identical parameters in the previous iteration and got the same results. Do NOT repeat the same calls. Either use the results you already have to form a final answer, or try a different approach."

  @signal_routes [
    {"ai.react.ask", Actions.Ask},
    {"ai.react.llm.completed", Actions.LLMTurn},
    {"ai.react.tool.completed", Actions.ToolResult},
    {"ai.react.failed", Actions.Failed}
  ]

  use Jido.Slice,
    name: "ai",
    path: :ai,
    description: "ReAct reasoning slice attached via `slices:` on a Jido.Agent.",
    actions: [
      Actions.Ask,
      Actions.LLMTurn,
      Actions.ToolResult,
      Actions.Failed
    ],
    schema:
      Zoi.object(
        %{
          status: Zoi.atom() |> Zoi.default(:idle),
          request_id: Zoi.any() |> Zoi.default(nil),
          context: Zoi.any() |> Zoi.default(nil),
          iteration: Zoi.integer() |> Zoi.default(0),
          max_iterations: Zoi.integer() |> Zoi.default(10),
          result: Zoi.any() |> Zoi.default(nil),
          error: Zoi.any() |> Zoi.default(nil),
          pending_tool_calls: Zoi.list(Zoi.any()) |> Zoi.default([]),
          tool_results_received: Zoi.list(Zoi.any()) |> Zoi.default([]),
          previous_tool_signature: Zoi.any() |> Zoi.default(nil),
          model: Zoi.any() |> Zoi.default(nil),
          tools: Zoi.list(Zoi.atom()) |> Zoi.default([]),
          system_prompt: Zoi.any() |> Zoi.default(nil),
          llm_opts: Zoi.any() |> Zoi.default([])
        },
        coerce: true
      ),
    config_schema:
      Zoi.object(
        %{
          model: Zoi.any() |> Zoi.optional(),
          tools: Zoi.list(Zoi.atom()) |> Zoi.default([]),
          system_prompt: Zoi.any() |> Zoi.optional(),
          max_iterations: Zoi.integer() |> Zoi.default(10),
          max_tokens: Zoi.integer() |> Zoi.default(4096),
          temperature: Zoi.any() |> Zoi.default(0.2),
          llm_opts: Zoi.any() |> Zoi.default([])
        },
        coerce: true
      )
      |> Zoi.transform({__MODULE__, :__fold_llm_opts__, []}),
    signal_routes: @signal_routes

  @doc false
  # Folds the convenience keys `:max_tokens` and `:temperature` into
  # `:llm_opts` so the slice carries a single keyword list of per-call
  # options. The state schema doesn't track them as separate fields; this
  # transform runs after `Zoi.parse(config_schema, ...)` and before the
  # config is merged into slice state.
  @spec __fold_llm_opts__(map(), term()) :: {:ok, map()}
  def __fold_llm_opts__(config, _ctx) when is_map(config) do
    {max_tokens, config} = Map.pop(config, :max_tokens)
    {temperature, config} = Map.pop(config, :temperature)
    base_opts = config[:llm_opts] || []

    llm_opts =
      base_opts
      |> put_unless_present(:max_tokens, max_tokens)
      |> put_unless_present(:temperature, temperature)

    {:ok, Map.put(config, :llm_opts, llm_opts)}
  end

  defp put_unless_present(opts, _key, nil), do: opts

  defp put_unless_present(opts, key, value) do
    if Keyword.has_key?(opts, key), do: opts, else: Keyword.put(opts, key, value)
  end

  @doc """
  The cycle-warning user message appended to the context when the next
  LLMCall would otherwise repeat the previous tool-call batch verbatim.
  """
  @spec cycle_warning() :: String.t()
  def cycle_warning, do: @cycle_warning

  @doc """
  Tool-call signature for cycle detection.

  Stable, sortable, and tolerant of mixed atom/string keys (different
  ReqLLM provider adapters return one or the other).
  """
  @spec tool_call_signature([map()]) :: String.t()
  def tool_call_signature(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(fn tc ->
      name = Map.get(tc, :name) || Map.get(tc, "name") || ""
      args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || ""
      "#{name}:#{inspect(args)}"
    end)
    |> Enum.sort()
    |> Enum.join("|")
  end
end
