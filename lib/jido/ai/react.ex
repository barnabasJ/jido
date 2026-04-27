defmodule Jido.AI.ReAct do
  @moduledoc """
  Synchronous ReAct loop over `ReqLLM.Generation.generate_text/3`.

  Drives a `reason → act → observe` cycle until the model produces a
  final answer, an error occurs, or `max_iterations` is reached.

  This module is the loop logic. To run a ReAct conversation under a
  Jido agent (with signals, observability, async tool exec), use the
  signal-driven envelope built on top of this loop. To run one-off,
  call `run/2` directly.

  ## Synchronous on purpose

  `run/2` blocks the caller until the loop terminates. A multi-iteration
  ReAct call against a slow model can block for tens of seconds. Callers
  who need async, observability, or steering should drive the loop from
  the agent envelope; one-off scripts and tests can call `run/2` directly.

  ## ADR 0019 conformance

  ADR 0019 forbids agent actions that mutate slice state from doing side
  effects. `Jido.AI.ReAct.run/2` is **not** an agent action — it is a
  top-level function that *uses* a model and tools to produce a result.
  Calling it from inside a `Jido.Action.run/4` would violate ADR 0019;
  drive it from a slice via a signal-driven envelope instead.

  ## Example

      result =
        Jido.AI.ReAct.run("What is 2 + 2?",
          model: "anthropic:claude-haiku-4-5-20251001",
          tools: [MyApp.Actions.Add],
          system_prompt: "You are a math assistant.",
          max_iterations: 5
        )

      result.text                 #=> "4"
      result.termination_reason   #=> :final_answer
      result.iterations           #=> 2
  """

  alias Jido.Action.Tool, as: ActionTool
  alias Jido.AI.{ToolAdapter, Turn}
  alias ReqLLM.Context

  defmodule Result do
    @moduledoc """
    Result of a `Jido.AI.ReAct.run/2` invocation.

    * `:text` — the final answer text from the model, or `nil` when the
      run terminated without producing a final answer (max iterations or
      error).
    * `:context` — the full `ReqLLM.Context` accumulated over the run,
      including the original user query, the system prompt (if any),
      every assistant turn, every tool result, and any cycle-warning
      messages injected by the loop.
    * `:iterations` — the number of LLM calls made.
    * `:termination_reason` — `:final_answer`, `:max_iterations`, or
      `:error`.
    * `:usage` — aggregated usage map (sum of per-turn `input_tokens`,
      `output_tokens`, etc.).
    * `:error` — the LLM error term when `termination_reason == :error`,
      otherwise `nil`.
    """

    @type t :: %__MODULE__{
            text: String.t() | nil,
            context: ReqLLM.Context.t(),
            iterations: non_neg_integer(),
            termination_reason: :final_answer | :max_iterations | :error,
            usage: map(),
            error: term() | nil
          }

    defstruct [:text, :context, :iterations, :termination_reason, :usage, :error]
  end

  @cycle_warning "You already called the same tool(s) with identical parameters in the previous iteration and got the same results. Do NOT repeat the same calls. Either use the results you already have to form a final answer, or try a different approach."

  @default_max_iterations 10
  @default_max_tokens 4096

  @type opts :: [
          model: ReqLLM.model_input(),
          tools: [module()],
          system_prompt: String.t() | nil,
          max_iterations: pos_integer(),
          temperature: float(),
          max_tokens: pos_integer(),
          llm_opts: keyword()
        ]

  @doc """
  Run the ReAct loop synchronously.

  ## Required options

    * `:model` — any value accepted by `ReqLLM.model/1` (a `"provider:id"`
      string, a `{provider, opts}` tuple, or a `%ReqLLM.Model{}` struct).

  ## Optional options

    * `:tools` — list of `Jido.Action` modules to expose. Defaults to `[]`.
    * `:system_prompt` — string prepended as the system message.
    * `:max_iterations` — cap on LLM calls. Defaults to `#{@default_max_iterations}`.
    * `:temperature` — passed through to `ReqLLM.Generation.generate_text/3`.
    * `:max_tokens` — passed through. Defaults to `#{@default_max_tokens}`.
    * `:llm_opts` — extra keyword list merged into the per-call options
      (last-write-wins over the defaults built from the other keys).
  """
  @spec run(String.t(), opts()) :: Result.t()
  def run(query, opts) when is_binary(query) and is_list(opts) do
    model = Keyword.fetch!(opts, :model)
    action_modules = Keyword.get(opts, :tools, [])
    system_prompt = Keyword.get(opts, :system_prompt)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    user_llm_opts = Keyword.get(opts, :llm_opts, [])

    tools = ToolAdapter.from_actions(action_modules)
    action_lookup = ToolAdapter.to_action_map(action_modules)

    base_llm_opts =
      [tools: tools, max_tokens: max_tokens]
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))

    llm_opts = Keyword.merge(base_llm_opts, user_llm_opts)

    state = %{
      context: build_initial_context(query, system_prompt),
      iterations: 0,
      max_iterations: max_iterations,
      model: model,
      llm_opts: llm_opts,
      action_lookup: action_lookup,
      previous_signature: nil,
      usage: %{}
    }

    loop(state)
  end

  defp build_initial_context(query, nil),
    do: Context.new([Context.user(query)])

  defp build_initial_context(query, system) when is_binary(system) do
    Context.new([Context.system(system), Context.user(query)])
  end

  defp loop(state) do
    iteration = state.iterations + 1

    if iteration > state.max_iterations do
      build_result(state, :max_iterations, nil, nil)
    else
      messages = Context.to_list(state.context)

      case ReqLLM.Generation.generate_text(state.model, messages, state.llm_opts) do
        {:ok, response} ->
          turn = Turn.from_response(response)

          state =
            %{state | iterations: iteration, usage: merge_usage(state.usage, turn.usage)}
            |> append_assistant(turn)

          handle_turn(state, turn)

        {:error, reason} ->
          state = %{state | iterations: iteration}
          build_result(state, :error, nil, reason)
      end
    end
  end

  defp handle_turn(state, %Turn{type: :final_answer, text: text}) do
    build_result(state, :final_answer, text, nil)
  end

  defp handle_turn(state, %Turn{type: :tool_calls, tool_calls: tool_calls}) do
    state
    |> run_tool_calls(tool_calls)
    |> maybe_append_cycle_warning(tool_calls)
    |> loop()
  end

  defp append_assistant(state, %Turn{type: :tool_calls, tool_calls: tool_calls, text: text}) do
    msg_calls =
      Enum.map(tool_calls, fn tc ->
        %{id: tc.id, name: tc.name, arguments: tc.arguments}
      end)

    msg = Context.assistant(text, tool_calls: msg_calls)
    %{state | context: Context.append(state.context, msg)}
  end

  defp append_assistant(state, %Turn{type: :final_answer, text: text}) do
    msg = Context.assistant(text)
    %{state | context: Context.append(state.context, msg)}
  end

  defp run_tool_calls(state, tool_calls) do
    Enum.reduce(tool_calls, state, fn tool_call, acc ->
      content = execute_tool_call(tool_call, acc.action_lookup)
      msg = Context.tool_result(tool_call.id, tool_call.name, content)
      %{acc | context: Context.append(acc.context, msg)}
    end)
  end

  defp execute_tool_call(%{name: name, arguments: args}, action_lookup) do
    case Map.fetch(action_lookup, name) do
      {:ok, module} ->
        params = ActionTool.convert_params_using_schema(args, module.schema())

        case Jido.Exec.run(module, params, %{}, []) do
          {:ok, result, _dirs} -> Jason.encode!(result)
          {:error, reason} -> Jason.encode!(%{error: format_error(reason)})
        end

      :error ->
        Jason.encode!(%{error: "tool not found: #{name}"})
    end
  end

  defp maybe_append_cycle_warning(state, tool_calls) do
    current_signature = tool_call_signature(tool_calls)

    cond do
      is_nil(state.previous_signature) ->
        %{state | previous_signature: current_signature}

      state.previous_signature == current_signature ->
        warned_context = Context.append(state.context, Context.user(@cycle_warning))
        %{state | context: warned_context, previous_signature: current_signature}

      true ->
        %{state | previous_signature: current_signature}
    end
  end

  # Tool call maps may arrive with atom or string keys depending on the
  # provider adapter, so we check both.
  defp tool_call_signature(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(fn tc ->
      name = Map.get(tc, :name) || Map.get(tc, "name") || ""
      args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || ""
      "#{name}:#{inspect(args)}"
    end)
    |> Enum.sort()
    |> Enum.join("|")
  end

  defp build_result(state, reason, text, error) do
    %Result{
      text: text,
      context: state.context,
      iterations: state.iterations,
      termination_reason: reason,
      usage: state.usage,
      error: error
    }
  end

  defp merge_usage(acc, nil), do: acc

  defp merge_usage(acc, usage) when is_map(usage) do
    Map.merge(acc, usage, fn
      _k, v1, v2 when is_number(v1) and is_number(v2) -> v1 + v2
      _k, _v1, v2 -> v2
    end)
  end

  defp format_error(%_{} = err) when is_exception(err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
