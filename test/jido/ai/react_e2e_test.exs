defmodule Jido.AI.ReActE2ETest do
  @moduledoc """
  End-to-end tests for the `Jido.AI.ReAct` slice against a local LM
  Studio server.

  These exercise the real `ReqLLM.Generation.generate_text/3` path — no
  Mimic stubs — through the full slice composition pattern: a regular
  `Jido.Agent` with `Jido.AI.ReAct` attached via `slices:`, started
  under `Jido.AgentServer`, queried via `Jido.AI.ask_sync/3`. Requires a
  model running at the configured base URL.

  The api key lives in the slice's `llm_opts: [api_key: ...]` (per-slice
  config); per-call overrides are also possible via the `:llm_opts` opt
  on `Jido.AI.ask/3`.

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
         max_tokens: 256,
         llm_opts: [api_key: System.get_env("LMSTUDIO_API_KEY", "lm-studio")]}
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
         max_tokens: 256,
         llm_opts: [api_key: System.get_env("LMSTUDIO_API_KEY", "lm-studio")]}
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
         max_tokens: 256,
         llm_opts: [api_key: System.get_env("LMSTUDIO_API_KEY", "lm-studio")]}
      ]
  end

  test "produces a final answer for a simple question without tools", ctx do
    pid = start_server(ctx, NoToolsAgent)

    assert {:ok, text} = Jido.AI.ask_sync(pid, "What is 2 + 2?", timeout: 60_000)

    assert is_binary(text)
    assert text =~ "4"
  end

  test "drives a tool-calling round trip when the model picks a tool", ctx do
    pid = start_server(ctx, EchoAgent)

    assert {:ok, text} =
             Jido.AI.ask_sync(
               pid,
               "You have a tool named test_echo that echoes a message. " <>
                 "Call it once with the message 'hello-from-jido', then reply 'done'.",
               timeout: 90_000
             )

    assert is_binary(text)

    {:ok, ai} = Jido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.ai} end)

    tool_messages =
      ai.context
      |> ReqLLM.Context.to_list()
      |> Enum.filter(&(&1.role == :tool))

    assert tool_messages != [], "expected the model to call test_echo at least once"
    assert hd(tool_messages).name == "test_echo"
  end

  test "handles a numeric tool call without crashing", ctx do
    pid = start_server(ctx, AddAgent)

    assert {:ok, text} =
             Jido.AI.ask_sync(
               pid,
               "You have a tool named test_add that adds two integers. " <>
                 "Use it to compute 4 + 7, then state the result.",
               timeout: 90_000
             )

    assert is_binary(text)
    assert text =~ "11"
  end

  test "out-of-band subscription observes every intermediate signal", ctx do
    pid = start_server(ctx, AddAgent)

    # Subscribe to every ai.react.* signal *before* casting (ADR 0021).
    # The selector projects slice status + iteration; subscribe/4's
    # default dispatch sends `{:jido_subscription, sub_ref, %{result:
    # {:ok, projection}}}` to the calling process for every non-:skip
    # selector return.
    {:ok, sub_ref} =
      Jido.AgentServer.subscribe(pid, "ai.react.**", fn state ->
        ai = state.agent.state.ai

        if is_nil(ai.request_id) do
          :skip
        else
          {:ok, %{status: ai.status, iteration: ai.iteration}}
        end
      end)

    assert {:ok, request_id} =
             Jido.AI.ask(
               pid,
               "You have a tool named test_add that adds two integers. " <>
                 "Use it to compute 4 + 7, then state the result."
             )

    assert is_binary(request_id)

    # Drain dispatches up to 90s, looking for the terminal :completed.
    # Along the way we expect at least one :running dispatch (Ask) and
    # at least one with iteration ≥ 1 (a tool turn landed). A :failed
    # dispatch surfaces as a flunk with the projection — it's the
    # canonical "model errored mid-run" signal and the test must fail
    # loudly when it happens.
    {max_iter, count} = drain_until_completed(sub_ref, 90_000)

    assert max_iter >= 1,
           "expected the model to drive at least one tool turn (iteration >= 1); got #{max_iter}"

    assert count >= 2,
           "expected multiple intermediate signals; received #{count}"

    :ok = Jido.AgentServer.unsubscribe(pid, sub_ref)
  end

  defp drain_until_completed(sub_ref, deadline_ms, acc \\ {0, 0})

  defp drain_until_completed(sub_ref, deadline_ms, {max_iter, count}) do
    receive do
      {:jido_subscription, ^sub_ref,
       %{result: {:ok, %{status: :completed, iteration: iter}}}} ->
        {max(max_iter, iter), count + 1}

      {:jido_subscription, ^sub_ref,
       %{result: {:ok, %{status: :failed} = projection}}} ->
        flunk("slice transitioned to :failed mid-run: #{inspect(projection)}")

      {:jido_subscription, ^sub_ref,
       %{result: {:ok, %{status: :running, iteration: iter}}}} ->
        drain_until_completed(sub_ref, deadline_ms, {max(max_iter, iter), count + 1})
    after
      deadline_ms ->
        flunk(
          "no :completed dispatch within #{deadline_ms}ms; saw #{count} non-terminal dispatches"
        )
    end
  end
end
