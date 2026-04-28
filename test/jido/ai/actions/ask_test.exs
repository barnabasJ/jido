defmodule Jido.AI.Actions.AskTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Actions.Ask
  alias Jido.AI.Directive.LLMCall
  alias Jido.AI.TestActions.TestAdd
  alias ReqLLM.Context

  defp ask_signal(overrides \\ %{}) do
    data =
      Map.merge(
        %{
          query: "What is 1 + 1?",
          request_id: "req_test_1",
          model: "anthropic:claude-haiku-4-5-20251001",
          tools: [TestAdd],
          system_prompt: "You are precise.",
          max_iterations: 4,
          llm_opts: [max_tokens: 64]
        },
        overrides
      )

    Jido.Signal.new!("ai.react.ask", data)
  end

  defp idle_slice do
    %{
      status: :idle,
      request_id: nil,
      context: nil,
      iteration: 0,
      max_iterations: 10,
      result: nil,
      error: nil,
      pending_tool_calls: [],
      tool_results_received: [],
      previous_tool_signature: nil,
      model: nil,
      tools: [],
      llm_opts: []
    }
  end

  test "transitions an idle slice to :running, seeds the context, and emits LLMCall" do
    {:ok, new_slice, [directive]} = Ask.run(ask_signal(), idle_slice(), %{}, %{})

    assert new_slice.status == :running
    assert new_slice.request_id == "req_test_1"
    assert new_slice.iteration == 0
    assert new_slice.max_iterations == 4
    assert new_slice.model == "anthropic:claude-haiku-4-5-20251001"
    assert new_slice.tools == [TestAdd]
    assert new_slice.llm_opts == [max_tokens: 64]
    assert new_slice.result == nil
    assert new_slice.error == nil
    assert new_slice.pending_tool_calls == []
    assert new_slice.tool_results_received == []
    assert new_slice.previous_tool_signature == nil

    messages = Context.to_list(new_slice.context)
    assert length(messages) == 2
    assert Enum.at(messages, 0).role == :system
    assert Enum.at(messages, 1).role == :user

    assert %LLMCall{
             model: "anthropic:claude-haiku-4-5-20251001",
             tools: [TestAdd],
             request_id: "req_test_1",
             llm_opts: [max_tokens: 64]
           } = directive

    assert directive.context == new_slice.context
  end

  test "omits the system message when no system_prompt is given" do
    {:ok, new_slice, [_]} =
      Ask.run(ask_signal(%{system_prompt: nil}), idle_slice(), %{}, %{})

    messages = Context.to_list(new_slice.context)
    assert length(messages) == 1
    assert hd(messages).role == :user
  end

  test "clears prior result/error when reopening a terminated slice" do
    slice =
      idle_slice()
      |> Map.merge(%{
        status: :completed,
        result: "prior",
        error: nil,
        request_id: "req_old",
        previous_tool_signature: "stale",
        pending_tool_calls: [%{id: "stale"}],
        tool_results_received: [%{id: "stale"}]
      })

    {:ok, new_slice, [_]} = Ask.run(ask_signal(), slice, %{}, %{})

    assert new_slice.status == :running
    assert new_slice.result == nil
    assert new_slice.error == nil
    assert new_slice.previous_tool_signature == nil
    assert new_slice.pending_tool_calls == []
    assert new_slice.tool_results_received == []
  end

  test "rejects a concurrent ask while the slice is :running" do
    slice = %{idle_slice() | status: :running, request_id: "req_inflight"}
    assert {:error, :busy} = Ask.run(ask_signal(), slice, %{}, %{})
  end

  test "accepts the ask when the slice is nil (uninitialized)" do
    {:ok, %{status: :running}, [%LLMCall{}]} = Ask.run(ask_signal(), nil, %{}, %{})
  end
end
