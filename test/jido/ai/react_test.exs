defmodule Jido.AI.ReActTest do
  use ExUnit.Case, async: true
  use Mimic

  import Jido.AI.Test.ResponseFixtures

  alias Jido.AI.ReAct
  alias Jido.AI.TestActions.{TestAdd, TestEcho, TestFails, TestMultiply}
  alias ReqLLM.Context

  @model "anthropic:claude-haiku-4-5-20251001"
  @cycle_warning "You already called the same tool(s) with identical parameters in the previous iteration and got the same results. Do NOT repeat the same calls. Either use the results you already have to form a final answer, or try a different approach."

  setup :verify_on_exit!

  describe "run/2" do
    test "returns a final answer on the first turn without invoking any tools" do
      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert length(messages) == 2
        assert Enum.at(messages, 0).role == :system
        assert Enum.at(messages, 1).role == :user
        {:ok, final_answer_response("42")}
      end)

      result =
        ReAct.run("What is the answer?",
          model: @model,
          tools: [],
          system_prompt: "You are helpful.",
          max_iterations: 5
        )

      assert result.text == "42"
      assert result.iterations == 1
      assert result.termination_reason == :final_answer
      assert result.error == nil
      assert is_map(result.usage)
    end

    test "executes a single tool call, then returns a final answer on the next turn" do
      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert length(messages) == 1
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert length(messages) == 3

        roles = Enum.map(messages, & &1.role)
        assert roles == [:user, :assistant, :tool]

        tool_msg = Enum.at(messages, 2)
        assert tool_msg.tool_call_id == "call_test_add_0"
        assert tool_msg.name == "test_add"

        {:ok, final_answer_response("Result is 3")}
      end)

      result =
        ReAct.run("Add 1 and 2",
          model: @model,
          tools: [TestAdd],
          max_iterations: 5
        )

      assert result.text == "Result is 3"
      assert result.iterations == 2
      assert result.termination_reason == :final_answer
      assert length(Context.to_list(result.context)) == 4
    end

    test "runs all tool calls within a single turn before issuing the next LLM call" do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok,
         tool_call_response([
           {"test_add", %{"a" => 2, "b" => 3}},
           {"test_multiply", %{"a" => 4, "b" => 5}}
         ])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        roles = Enum.map(messages, & &1.role)
        assert roles == [:user, :assistant, :tool, :tool]
        {:ok, final_answer_response("done")}
      end)

      result =
        ReAct.run("Compute things",
          model: @model,
          tools: [TestAdd, TestMultiply],
          max_iterations: 5
        )

      assert result.iterations == 2
      assert result.termination_reason == :final_answer
    end

    test "captures a tool execution error in the conversation and continues to a final answer" do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_fails", %{"reason" => "boom"}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        tool_msg = Enum.find(messages, &(&1.role == :tool))
        assert tool_msg, "expected a tool result message in the conversation"

        text = first_text_content(tool_msg)
        assert text =~ "error"
        assert text =~ "boom"

        {:ok, final_answer_response("recovered")}
      end)

      result =
        ReAct.run("Try the failing tool",
          model: @model,
          tools: [TestFails],
          max_iterations: 5
        )

      assert result.text == "recovered"
      assert result.termination_reason == :final_answer
      assert result.iterations == 2
    end

    test "records a 'tool not found' error blob when the model picks an unknown tool" do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"ghost", %{"x" => 1}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        tool_msg = Enum.find(messages, &(&1.role == :tool))
        assert tool_msg

        text = first_text_content(tool_msg)
        assert text =~ "tool not found"
        assert text =~ "ghost"

        {:ok, final_answer_response("ok, no ghost tool here")}
      end)

      result =
        ReAct.run("Call ghost",
          model: @model,
          tools: [TestEcho],
          max_iterations: 5
        )

      assert result.termination_reason == :final_answer
      assert result.iterations == 2
    end

    test "stops at max_iterations when the model never produces a final answer" do
      expect(ReqLLM.Generation, :generate_text, 10, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 1}}])}
      end)

      result =
        ReAct.run("loop forever",
          model: @model,
          tools: [TestAdd],
          max_iterations: 10
        )

      assert result.termination_reason == :max_iterations
      assert result.iterations == 10
      assert result.text == nil
    end

    test "appends the cycle warning when consecutive turns issue identical tool calls" do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        warning_msg =
          Enum.find(messages, fn msg ->
            msg.role == :user and first_text_content(msg) == @cycle_warning
          end)

        assert warning_msg, "expected the cycle warning to be appended before the third LLM call"

        {:ok, final_answer_response("ok")}
      end)

      result =
        ReAct.run("repeat yourself",
          model: @model,
          tools: [TestAdd],
          max_iterations: 5
        )

      assert result.iterations == 3
      assert result.termination_reason == :final_answer
    end

    test "returns an error result when the LLM call fails" do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:error, :rate_limited}
      end)

      result =
        ReAct.run("hi",
          model: @model,
          tools: [],
          max_iterations: 5
        )

      assert result.termination_reason == :error
      assert result.error == :rate_limited
      assert result.text == nil
      assert result.iterations == 1
    end

    test "passes tools: [] in opts when no actions are provided" do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, opts ->
        assert Keyword.fetch!(opts, :tools) == []
        {:ok, final_answer_response("no tools here")}
      end)

      result =
        ReAct.run("nothing to do",
          model: @model,
          tools: [],
          max_iterations: 3
        )

      assert result.text == "no tools here"
      assert result.termination_reason == :final_answer
    end

    test "places the system prompt at index 0 of the projected messages list" do
      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        first = Enum.at(messages, 0)
        assert first.role == :system
        assert first_text_content(first) == "Be terse."

        {:ok, final_answer_response("k")}
      end)

      result =
        ReAct.run("hi",
          model: @model,
          tools: [],
          system_prompt: "Be terse.",
          max_iterations: 1
        )

      assert result.text == "k"
    end
  end

  defp first_text_content(%ReqLLM.Message{
         content: [%ReqLLM.Message.ContentPart{type: :text, text: text} | _]
       }),
       do: text

  defp first_text_content(_), do: nil
end
