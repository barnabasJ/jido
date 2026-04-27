defmodule Jido.AI.TurnTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Turn
  alias ReqLLM.Context
  alias ReqLLM.Message.{ContentPart, ReasoningDetails}
  alias ReqLLM.{Response, ToolCall}

  defp build_response(message, fields) do
    defaults = [
      id: "resp_test",
      model: "anthropic:claude-haiku-4-5-20251001",
      context: Context.new(),
      message: message,
      stream?: false,
      stream: nil,
      usage: %{input_tokens: 10, output_tokens: 5},
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    ]

    struct!(Response, Keyword.merge(defaults, fields))
  end

  describe "from_response/2" do
    test "final-answer response (text content only) yields :final_answer with populated text" do
      message =
        Context.assistant("Hello, world!", metadata: %{response_id: "resp_final"})

      response = build_response(message, finish_reason: :stop)

      turn = Turn.from_response(response)

      assert turn.type == :final_answer
      assert turn.text == "Hello, world!"
      assert turn.tool_calls == []
      assert turn.thinking_content == nil
      assert turn.reasoning_details == nil
      assert turn.finish_reason == :stop
      assert turn.model == "anthropic:claude-haiku-4-5-20251001"
      assert turn.usage == %{input_tokens: 10, output_tokens: 5}
      assert turn.message_metadata == %{response_id: "resp_final"}
    end

    test "tool-calling response yields :tool_calls with populated tool_calls" do
      tool_call = ToolCall.new("tc_1", "calculator", ~s({"a":1,"b":2}))

      message =
        Context.assistant("",
          tool_calls: [tool_call],
          metadata: %{response_id: "resp_tools"}
        )

      response = build_response(message, finish_reason: :tool_calls)

      turn = Turn.from_response(response)

      assert turn.type == :tool_calls
      assert turn.text == ""
      assert turn.finish_reason == :tool_calls

      assert turn.tool_calls == [
               %{id: "tc_1", name: "calculator", arguments: %{"a" => 1, "b" => 2}}
             ]
    end

    test "mixed text + tool_use response yields :tool_calls and preserves leading text" do
      tool_call = ToolCall.new("tc_2", "weather", ~s({"city":"Paris"}))

      message =
        Context.assistant("Let me check the weather for you.",
          tool_calls: [tool_call],
          metadata: %{}
        )

      response = build_response(message, finish_reason: :tool_calls)

      turn = Turn.from_response(response)

      assert turn.type == :tool_calls
      assert turn.text == "Let me check the weather for you."

      assert turn.tool_calls == [
               %{id: "tc_2", name: "weather", arguments: %{"city" => "Paris"}}
             ]
    end

    test "extracts thinking content from thinking content parts" do
      thinking_part = ContentPart.thinking("Let me reason about this...")
      text_part = ContentPart.text("Final answer: 42.")

      message =
        Context.assistant([thinking_part, text_part], metadata: %{})

      response = build_response(message, finish_reason: :stop)

      turn = Turn.from_response(response)

      assert turn.type == :final_answer
      assert turn.text == "Final answer: 42."
      assert turn.thinking_content == "Let me reason about this..."
    end

    test "carries reasoning_details through for multi-turn continuity" do
      reasoning = [
        %ReasoningDetails{
          text: "Step-by-step reasoning",
          signature: "sig_abc",
          encrypted?: false,
          provider: :anthropic,
          format: "thinking/v1",
          index: 0,
          provider_data: %{}
        }
      ]

      message =
        Context.assistant("done", metadata: %{})
        |> Map.put(:reasoning_details, reasoning)

      response = build_response(message, finish_reason: :stop)

      turn = Turn.from_response(response)

      assert turn.reasoning_details == reasoning
    end

    test ":model opt overrides the model string from the response" do
      message = Context.assistant("answer", metadata: %{})

      response = build_response(message, model: "google:gemini-2.0-flash")

      turn = Turn.from_response(response, model: "openai:gpt-5")

      assert turn.model == "openai:gpt-5"
    end

    test "passing an existing Turn returns it unchanged when no opts" do
      original = %Turn{
        type: :final_answer,
        text: "hi",
        model: "anthropic:claude-haiku"
      }

      assert Turn.from_response(original) == original
    end

    test "passing an existing Turn with :model overrides only the model" do
      original = %Turn{
        type: :final_answer,
        text: "hi",
        model: "anthropic:claude-haiku"
      }

      assert Turn.from_response(original, model: "openai:gpt-5") ==
               %{original | model: "openai:gpt-5"}
    end
  end

  describe "needs_tools?/1" do
    test ":final_answer turn returns false" do
      refute Turn.needs_tools?(%Turn{type: :final_answer, tool_calls: []})
    end

    test ":tool_calls turn with empty list returns false" do
      refute Turn.needs_tools?(%Turn{type: :tool_calls, tool_calls: []})
    end

    test ":tool_calls turn with one or more tool calls returns true" do
      turn = %Turn{
        type: :tool_calls,
        tool_calls: [%{id: "tc_1", name: "x", arguments: %{}}]
      }

      assert Turn.needs_tools?(turn)
    end

    test ":tool_calls turn with multiple tool calls returns true" do
      turn = %Turn{
        type: :tool_calls,
        tool_calls: [
          %{id: "tc_1", name: "x", arguments: %{}},
          %{id: "tc_2", name: "y", arguments: %{}}
        ]
      }

      assert Turn.needs_tools?(turn)
    end
  end
end
