defmodule Jido.AI.Test.ResponseFixtures do
  @moduledoc false

  alias ReqLLM.{Context, Response, ToolCall}

  @default_model "anthropic:claude-haiku-4-5-20251001"

  @doc """
  Builds a `ReqLLM.Response` with a final-answer assistant message.
  """
  @spec final_answer_response(String.t(), keyword()) :: Response.t()
  def final_answer_response(text, opts \\ []) when is_binary(text) do
    message = Context.assistant(text)

    build_response(message,
      finish_reason: :stop,
      usage: Keyword.get(opts, :usage, %{input_tokens: 10, output_tokens: 5})
    )
  end

  @doc """
  Builds a `ReqLLM.Response` representing a tool-call turn.

  Each call is `{name, args_map}` or `{name, args_map, id}`. When the id
  is omitted a deterministic `"call_<name>_<i>"` is generated.
  """
  @spec tool_call_response([{String.t(), map()} | {String.t(), map(), String.t()}], keyword()) ::
          Response.t()
  def tool_call_response(calls, opts \\ []) when is_list(calls) do
    tool_calls = build_tool_calls(calls)
    message = Context.assistant("", tool_calls: tool_calls)

    build_response(message,
      finish_reason: :tool_calls,
      usage: Keyword.get(opts, :usage, %{input_tokens: 12, output_tokens: 6})
    )
  end

  @doc """
  Builds a `ReqLLM.Response` with both leading text and tool calls.
  """
  @spec mixed_response(
          String.t(),
          [{String.t(), map()} | {String.t(), map(), String.t()}],
          keyword()
        ) ::
          Response.t()
  def mixed_response(text, calls, opts \\ []) when is_binary(text) and is_list(calls) do
    tool_calls = build_tool_calls(calls)
    message = Context.assistant(text, tool_calls: tool_calls)

    build_response(message,
      finish_reason: :tool_calls,
      usage: Keyword.get(opts, :usage, %{input_tokens: 14, output_tokens: 8})
    )
  end

  defp build_tool_calls(calls) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn
      {{name, args}, idx} ->
        ToolCall.new("call_#{name}_#{idx}", name, Jason.encode!(args))

      {{name, args, id}, _idx} ->
        ToolCall.new(id, name, Jason.encode!(args))
    end)
  end

  defp build_response(message, fields) do
    defaults = [
      id: "resp_test_#{System.unique_integer([:positive])}",
      model: @default_model,
      context: Context.new(),
      message: message,
      stream?: false,
      stream: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    ]

    struct!(Response, Keyword.merge(defaults, fields))
  end
end
