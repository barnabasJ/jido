defmodule Jido.AI.Directive.LLMCallTest do
  # async: false because the directive's executor spawns a Task that
  # calls `ReqLLM.Generation.generate_text/3`. The Mimic stub on that
  # function must be visible from the spawned process — `set_mimic_global/0`
  # provides that, and global mode is mutually exclusive with async tests.
  use JidoTest.Case, async: false
  use Mimic

  import Jido.AI.Test.ResponseFixtures

  alias Jido.AI.Directive.LLMCall
  alias Jido.AI.TestActions.TestAdd
  alias Jido.AI.Turn
  alias ReqLLM.Context

  setup :set_mimic_global
  setup :verify_on_exit!

  defp directive(opts \\ []) do
    %LLMCall{
      model: Keyword.get(opts, :model, "anthropic:claude-haiku-4-5-20251001"),
      context: Keyword.get(opts, :context, Context.new([Context.user("hi")])),
      tools: Keyword.get(opts, :tools, [TestAdd]),
      request_id: Keyword.get(opts, :request_id, "req_1"),
      llm_opts: Keyword.get(opts, :llm_opts, max_tokens: 64)
    }
  end

  defp fake_state(jido), do: %{id: "stub-agent", jido: jido}

  # Stand-in for the agent process: forwards every cast it receives back
  # to the test pid so we can assert on the cast signal shape.
  defp spawn_agent_stub(target_pid) do
    spawn_link(fn -> forward(target_pid) end)
  end

  defp forward(target) do
    receive do
      {:"$gen_cast", {:signal, signal}} ->
        send(target, {:cast, signal})
        forward(target)

      {:run, fun, from} ->
        send(from, {:run_done, fun.()})
        forward(target)

      _ ->
        forward(target)
    end
  end

  defp run_in(pid, fun) do
    send(pid, {:run, fun, self()})

    receive do
      {:run_done, result} -> result
    after
      1_000 -> :timeout
    end
  end

  test "spawns a task, calls ReqLLM, and casts ai.react.llm.completed back", %{jido: jido} do
    test_pid = self()

    expect(ReqLLM.Generation, :generate_text, fn _model, messages, opts ->
      send(test_pid, {:reqllm_called, length(messages), Keyword.fetch!(opts, :tools)})
      {:ok, final_answer_response("ok")}
    end)

    agent = spawn_agent_stub(test_pid)

    :ok =
      run_in(agent, fn ->
        Jido.AgentServer.DirectiveExec.exec(directive(), :input_signal, fake_state(jido))
      end)

    assert_receive {:reqllm_called, 1, [_]}, 1_000
    assert_receive {:cast, signal}, 1_000

    assert signal.type == "ai.react.llm.completed"
    assert signal.data.request_id == "req_1"
    assert %Turn{type: :final_answer, text: "ok"} = signal.data.turn
  end

  test "casts ai.react.failed when ReqLLM returns an error", %{jido: jido} do
    test_pid = self()

    expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
      {:error, :rate_limited}
    end)

    agent = spawn_agent_stub(test_pid)

    :ok =
      run_in(agent, fn ->
        Jido.AgentServer.DirectiveExec.exec(directive(), :input_signal, fake_state(jido))
      end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "ai.react.failed"
    assert signal.data == %{reason: :rate_limited, request_id: "req_1"}
  end
end
