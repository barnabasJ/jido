defmodule Jido.AI.Actions.ToolResultTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Actions.ToolResult
  alias Jido.AI.Directive.LLMCall
  alias Jido.AI.Slice
  alias Jido.AI.TestActions.TestAdd
  alias ReqLLM.Context

  defp slice_with_pending(calls, opts \\ []) do
    %{
      status: :running,
      request_id: Keyword.get(opts, :request_id, "req_1"),
      context: Keyword.get(opts, :context, Context.new([Context.user("hi")])),
      iteration: Keyword.get(opts, :iteration, 1),
      max_iterations: 4,
      result: nil,
      error: nil,
      pending_tool_calls: calls,
      tool_results_received: [],
      previous_tool_signature: Keyword.get(opts, :previous_tool_signature, nil),
      model: "anthropic:claude-haiku-4-5-20251001",
      tools: [TestAdd],
      llm_opts: []
    }
  end

  defp signal(request_id, tool_call_id, name, content) do
    Jido.Signal.new!("ai.react.tool.completed", %{
      request_id: request_id,
      tool_call_id: tool_call_id,
      name: name,
      content: content
    })
  end

  test "appends a result to the context but does not emit until the batch is full" do
    calls = [
      %{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}},
      %{id: "call_2", name: "test_add", arguments: %{"a" => 3, "b" => 4}}
    ]

    slice = slice_with_pending(calls)

    {:ok, new_slice, directives} =
      ToolResult.run(signal("req_1", "call_1", "test_add", "{\"result\":3}"), slice, %{}, %{})

    assert directives == []
    assert length(new_slice.tool_results_received) == 1
    assert new_slice.pending_tool_calls == calls

    messages = Context.to_list(new_slice.context)
    assert List.last(messages).role == :tool
  end

  test "emits the next LLMCall when all results are in" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    slice = slice_with_pending(calls)

    {:ok, new_slice, [%LLMCall{} = directive]} =
      ToolResult.run(signal("req_1", "call_1", "test_add", "{\"result\":3}"), slice, %{}, %{})

    assert new_slice.pending_tool_calls == []
    assert new_slice.tool_results_received == []
    assert new_slice.previous_tool_signature == Slice.tool_call_signature(calls)

    assert directive.context == new_slice.context
    assert directive.model == slice.model
    assert directive.tools == slice.tools
    assert directive.request_id == slice.request_id
    assert directive.llm_opts == slice.llm_opts
  end

  test "appends the cycle warning when the batch repeats the previous signature" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    previous_signature = Slice.tool_call_signature(calls)

    slice = slice_with_pending(calls, previous_tool_signature: previous_signature)

    {:ok, new_slice, [%LLMCall{} = directive]} =
      ToolResult.run(signal("req_1", "call_1", "test_add", "{\"result\":3}"), slice, %{}, %{})

    messages = Context.to_list(new_slice.context)
    last = List.last(messages)
    assert last.role == :user

    text = last.content |> hd() |> Map.get(:text)
    assert text == Slice.cycle_warning()
    assert directive.context == new_slice.context
  end

  test "does not append the cycle warning on the first tool batch" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    slice = slice_with_pending(calls, previous_tool_signature: nil)

    {:ok, new_slice, [%LLMCall{}]} =
      ToolResult.run(signal("req_1", "call_1", "test_add", "{\"result\":3}"), slice, %{}, %{})

    messages = Context.to_list(new_slice.context)
    refute List.last(messages).role == :user
  end

  test "drops stale signals — request_id mismatch" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    slice = slice_with_pending(calls, request_id: "req_active")

    {:ok, returned, []} =
      ToolResult.run(signal("req_old", "call_1", "test_add", "{}"), slice, %{}, %{})

    assert returned == slice
  end

  test "drops signals that arrive after the slice terminated" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    slice = %{slice_with_pending(calls) | status: :completed, result: "earlier"}

    {:ok, returned, []} =
      ToolResult.run(signal("req_1", "call_1", "test_add", "{}"), slice, %{}, %{})

    assert returned == slice
  end
end
