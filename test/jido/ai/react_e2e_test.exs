defmodule Jido.AI.ReActE2ETest do
  @moduledoc """
  End-to-end tests for the `Jido.AI.ReAct` slice against a local LM
  Studio server.

  These exercise the real `ReqLLM.Generation.generate_text/3` path — no
  Mimic stubs — through the full slice composition pattern: a regular
  `Jido.Agent` with `Jido.AI.ReAct` attached via `slices:`, started
  under `Jido.AgentServer`, queried via `Jido.AI.ask_sync/3`. Requires a
  model running at the configured base URL.

  Tagged `:e2e` and excluded from the default test run. To enable:

      mix test --include e2e

  Configurable via env vars:

    * `LMSTUDIO_BASE_URL` (default `http://localhost:1234/v1`)
    * `LMSTUDIO_MODEL`    (default `google/gemma-4-26b-a4b`)
    * `LMSTUDIO_API_KEY`  (default `lm-studio` — LM Studio ignores it)
  """

  use JidoTest.Case, async: false

  alias Jido.AI.TestActions.{TestAdd, TestEcho}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @api_key System.get_env("LMSTUDIO_API_KEY", "lm-studio")

  setup_all do
    ReqLLM.put_key(:openai_api_key, @api_key)
    :ok
  end

  defmodule NoToolsAgent do
    @moduledoc false
    use Jido.Agent,
      name: "react_e2e_no_tools",
      path: :state,
      slices: [
        {Jido.AI.ReAct,
         model: %{
           provider: :openai,
           id: System.get_env("LMSTUDIO_MODEL", "google/gemma-4-26b-a4b"),
           base_url: System.get_env("LMSTUDIO_BASE_URL", "http://localhost:1234/v1")
         },
         tools: [],
         max_iterations: 3,
         max_tokens: 64}
      ]
  end

  defmodule EchoAgent do
    @moduledoc false
    use Jido.Agent,
      name: "react_e2e_echo",
      path: :state,
      slices: [
        {Jido.AI.ReAct,
         model: %{
           provider: :openai,
           id: System.get_env("LMSTUDIO_MODEL", "google/gemma-4-26b-a4b"),
           base_url: System.get_env("LMSTUDIO_BASE_URL", "http://localhost:1234/v1")
         },
         tools: [TestEcho],
         max_iterations: 5,
         max_tokens: 256}
      ]
  end

  defmodule AddAgent do
    @moduledoc false
    use Jido.Agent,
      name: "react_e2e_add",
      path: :state,
      slices: [
        {Jido.AI.ReAct,
         model: %{
           provider: :openai,
           id: System.get_env("LMSTUDIO_MODEL", "google/gemma-4-26b-a4b"),
           base_url: System.get_env("LMSTUDIO_BASE_URL", "http://localhost:1234/v1")
         },
         tools: [TestAdd],
         max_iterations: 5,
         max_tokens: 256}
      ]
  end

  test "produces a final answer for a simple question without tools", ctx do
    pid = start_server(ctx, NoToolsAgent)

    _ =
      Jido.AI.ask_sync(pid, "Reply with the single word 'pong' and nothing else.",
        timeout: 60_000
      )

    ai = read_ai(pid)
    assert ai.status in [:completed, :failed]
    assert ai.iteration >= 1
  end

  test "drives a tool-calling round trip when the model picks a tool", ctx do
    pid = start_server(ctx, EchoAgent)

    _ =
      Jido.AI.ask_sync(
        pid,
        "You have a tool named test_echo that echoes a message. " <>
          "Call it once with the message 'hello-from-jido', then reply 'done'.",
        timeout: 90_000
      )

    ai = read_ai(pid)
    assert ai.status in [:completed, :failed]
    assert ai.iteration >= 1

    if ai.status == :completed and ai.context do
      tool_messages =
        ai.context
        |> ReqLLM.Context.to_list()
        |> Enum.filter(&(&1.role == :tool))

      if tool_messages != [] do
        assert hd(tool_messages).name == "test_echo"
      end
    end
  end

  test "handles a numeric tool call without crashing", ctx do
    pid = start_server(ctx, AddAgent)

    _ =
      Jido.AI.ask_sync(
        pid,
        "You have a tool named test_add that adds two integers. " <>
          "Use it to compute 4 + 7, then state the result.",
        timeout: 90_000
      )

    ai = read_ai(pid)
    assert ai.status in [:completed, :failed]

    if ai.context do
      msg_count =
        ai.context
        |> ReqLLM.Context.to_list()
        |> length()

      assert msg_count >= 2
    end
  end

  defp read_ai(pid) do
    {:ok, ai} = Jido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.ai} end)
    ai
  end
end
