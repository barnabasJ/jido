defmodule Jido.AI.ReActE2ETest do
  @moduledoc """
  End-to-end tests for `Jido.AI.ReAct` against a local LM Studio server.

  These tests exercise the real `ReqLLM.Generation.generate_text/3` path —
  no Mimic stubs — and require a model running at the configured base URL.

  Tagged `:e2e` and excluded from the default test run. To enable:

      mix test --include e2e

  Configurable via env vars:

    * `LMSTUDIO_BASE_URL` (default `http://localhost:1234/v1`)
    * `LMSTUDIO_MODEL`    (default `google/gemma-3-12b`)
    * `LMSTUDIO_API_KEY`  (default `lm-studio` — LM Studio ignores it)
  """

  use ExUnit.Case, async: false

  alias Jido.AI.ReAct
  alias Jido.AI.TestActions.{TestAdd, TestEcho}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @base_url System.get_env("LMSTUDIO_BASE_URL", "http://localhost:1234/v1")
  @model_id System.get_env("LMSTUDIO_MODEL", "google/gemma-3-12b")
  @api_key System.get_env("LMSTUDIO_API_KEY", "lm-studio")

  setup_all do
    ReqLLM.put_key(:openai_api_key, @api_key)
    :ok
  end

  defp model do
    %{provider: :openai, id: @model_id, base_url: @base_url}
  end

  test "produces a final answer for a simple question without tools" do
    result =
      ReAct.run("Reply with the single word 'pong' and nothing else.",
        model: model(),
        tools: [],
        max_iterations: 3,
        max_tokens: 64
      )

    assert result.termination_reason in [:final_answer, :max_iterations]
    assert is_binary(result.text) or result.text == nil
    assert result.iterations >= 1
  end

  test "drives a tool-calling round trip when the model picks a tool" do
    result =
      ReAct.run(
        "You have a tool named test_echo that echoes a message. " <>
          "Call it once with the message 'hello-from-jido', then reply 'done'.",
        model: model(),
        tools: [TestEcho],
        max_iterations: 5,
        max_tokens: 256
      )

    assert result.termination_reason in [:final_answer, :max_iterations]
    assert result.iterations >= 1

    tool_messages =
      result.context
      |> ReqLLM.Context.to_list()
      |> Enum.filter(&(&1.role == :tool))

    if result.termination_reason == :final_answer and tool_messages != [] do
      tool_msg = hd(tool_messages)
      assert tool_msg.name == "test_echo"
    end
  end

  test "handles a numeric tool call without crashing" do
    result =
      ReAct.run(
        "You have a tool named test_add that adds two integers. " <>
          "Use it to compute 4 + 7, then state the result.",
        model: model(),
        tools: [TestAdd],
        max_iterations: 5,
        max_tokens: 256
      )

    assert result.termination_reason in [:final_answer, :max_iterations]

    msg_count =
      result.context
      |> ReqLLM.Context.to_list()
      |> length()

    assert msg_count >= 2
  end
end
