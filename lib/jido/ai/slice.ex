defmodule Jido.AI.Slice do
  @moduledoc """
  ReAct strategy expressed as a Jido slice.

  The slice owns the `:ai` key of an agent's state and contains the full
  lifecycle of one ReAct conversation. It exposes:

    * a Zoi schema describing the slice's fields and their defaults,
    * the four actions that mutate that state in response to signals, and
    * the four absolute signal routes that wire those signals into the
      actions.

  `Jido.AI.Agent`'s `use` macro reads `path/0`, `schema/0`, and
  `signal_routes/0` directly off this module and forwards them to
  `use Jido.Agent`. The slice is **not** attached as a plugin — it is the
  agent's own slice.

  ## State machine

      :idle ──ask──▶ :running ─┬─final answer──▶ :completed
                               ├─tool calls + iter < max ─▶ :running (next iter)
                               ├─tool calls + iter ≥ max ─▶ :completed (truncated)
                               └─LLM error ──▶ :failed

  Concurrent `ai.react.ask` while `:running` is rejected with
  `{:error, :busy}` (ADR 0022 §5).

  ## Slice fields

    * `:status` — `:idle | :running | :completed | :failed`.
    * `:request_id` — opaque correlation id minted by `Jido.AI.Agent.ask/3`.
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
    * `:model`, `:tools`, `:llm_opts` — run config seeded by the opening
      `Ask` action and reused by every subsequent `LLMCall` directive in
      the same run.
  """

  alias Jido.AI.Actions

  @signal_routes [
    {"ai.react.ask", Actions.Ask},
    {"ai.react.llm.completed", Actions.LLMTurn},
    {"ai.react.tool.completed", Actions.ToolResult},
    {"ai.react.failed", Actions.Failed}
  ]

  use Jido.Slice,
    name: "ai",
    path: :ai,
    description: "ReAct strategy slice for Jido.AI.Agent.",
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
          llm_opts: Zoi.any() |> Zoi.default([])
        },
        coerce: true
      ),
    signal_routes: @signal_routes

  @cycle_warning "You already called the same tool(s) with identical parameters in the previous iteration and got the same results. Do NOT repeat the same calls. Either use the results you already have to form a final answer, or try a different approach."

  @doc """
  The cycle-warning user message appended to the context when the next
  LLMCall would otherwise repeat the previous tool-call batch verbatim.

  Same string as `Jido.AI.ReAct`'s synchronous loop so behaviour matches
  across both runners.
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
