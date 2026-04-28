defmodule Jido.AI.Actions.LLMTurnTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Actions.LLMTurn
  alias Jido.AI.Directive.ToolExec
  alias Jido.AI.TestActions.TestAdd
  alias Jido.AI.Turn
  alias ReqLLM.Context

  defp running_slice(opts \\ []) do
    %{
      status: :running,
      request_id: Keyword.get(opts, :request_id, "req_1"),
      context: Keyword.get(opts, :context, Context.new([Context.user("hi")])),
      iteration: Keyword.get(opts, :iteration, 0),
      max_iterations: Keyword.get(opts, :max_iterations, 4),
      result: nil,
      error: nil,
      pending_tool_calls: [],
      tool_results_received: [],
      previous_tool_signature: Keyword.get(opts, :previous_tool_signature, nil),
      model: "anthropic:claude-haiku-4-5-20251001",
      tools: Keyword.get(opts, :tools, [TestAdd]),
      llm_opts: []
    }
  end

  defp signal(request_id, turn) do
    Jido.Signal.new!("ai.react.llm.completed", %{turn: turn, request_id: request_id})
  end

  defp final_turn(text), do: %Turn{type: :final_answer, text: text, tool_calls: []}

  defp tool_turn(calls, opts \\ []) do
    %Turn{
      type: :tool_calls,
      text: Keyword.get(opts, :text, ""),
      tool_calls: calls
    }
  end

  describe "final answer turn" do
    test "appends the assistant message and settles :completed with the text" do
      {:ok, new_slice, directives} =
        LLMTurn.run(signal("req_1", final_turn("42")), running_slice(), %{}, %{})

      assert directives == []
      assert new_slice.status == :completed
      assert new_slice.result == "42"
      assert new_slice.iteration == 1

      messages = Context.to_list(new_slice.context)
      assert List.last(messages).role == :assistant
    end
  end

  describe "tool calls turn" do
    test "stores pending calls, emits one ToolExec per call, increments iteration" do
      calls = [
        %{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}
      ]

      {:ok, new_slice, directives} =
        LLMTurn.run(signal("req_1", tool_turn(calls)), running_slice(), %{}, %{})

      assert new_slice.status == :running
      assert new_slice.iteration == 1
      assert length(new_slice.pending_tool_calls) == 1
      assert new_slice.tool_results_received == []
      # LLMTurn does NOT update previous_tool_signature — that's ToolResult's job.
      assert new_slice.previous_tool_signature == nil

      assert [%ToolExec{tool_call: tc, tool_modules: [TestAdd], request_id: "req_1"}] = directives
      assert tc.id == "call_1"

      messages = Context.to_list(new_slice.context)
      assistant = List.last(messages)
      assert assistant.role == :assistant
    end

    test "dispatches one ToolExec per parallel tool call" do
      calls = [
        %{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}},
        %{id: "call_2", name: "test_add", arguments: %{"a" => 3, "b" => 4}}
      ]

      {:ok, new_slice, directives} =
        LLMTurn.run(signal("req_1", tool_turn(calls)), running_slice(), %{}, %{})

      assert length(new_slice.pending_tool_calls) == 2
      assert length(directives) == 2
      assert Enum.all?(directives, &match?(%ToolExec{}, &1))
    end

    test "settles :completed (truncated, result nil) when the cap is hit" do
      slice = running_slice(iteration: 3, max_iterations: 4)

      calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]

      {:ok, new_slice, directives} =
        LLMTurn.run(signal("req_1", tool_turn(calls)), slice, %{}, %{})

      assert directives == []
      assert new_slice.status == :completed
      assert new_slice.result == nil
      assert new_slice.iteration == 4
    end
  end

  describe "stale and post-terminal signals" do
    test "drops a signal whose request_id doesn't match the slice" do
      slice = running_slice(request_id: "req_active")

      {:ok, returned, []} =
        LLMTurn.run(signal("req_old", final_turn("ignored")), slice, %{}, %{})

      assert returned == slice
    end

    test "drops a signal that arrives after the slice has already terminated" do
      slice = %{running_slice() | status: :completed, result: "earlier"}

      {:ok, returned, []} =
        LLMTurn.run(signal("req_1", final_turn("ignored")), slice, %{}, %{})

      assert returned == slice
    end
  end
end
