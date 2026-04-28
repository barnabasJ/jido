defmodule Jido.AI.Actions.FailedTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Actions.Failed

  defp signal(request_id, reason) do
    Jido.Signal.new!("ai.react.failed", %{reason: reason, request_id: request_id})
  end

  defp running_slice(request_id) do
    %{
      status: :running,
      request_id: request_id,
      context: nil,
      iteration: 1,
      max_iterations: 4,
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

  test "settles a matching :running slice to :failed and stores the reason" do
    {:ok, new_slice, []} =
      Failed.run(signal("req_match", :rate_limited), running_slice("req_match"), %{}, %{})

    assert new_slice.status == :failed
    assert new_slice.error == :rate_limited
  end

  test "drops stale signals — request_id mismatch leaves the slice untouched" do
    slice = running_slice("req_active")

    {:ok, returned_slice, []} =
      Failed.run(signal("req_old", :anything), slice, %{}, %{})

    assert returned_slice == slice
  end

  test "drops the signal when the slice has already terminated" do
    slice = %{running_slice("req_done") | status: :completed, result: "earlier answer"}

    {:ok, returned_slice, []} =
      Failed.run(signal("req_done", :late), slice, %{}, %{})

    assert returned_slice == slice
  end
end
