defmodule Jido.AITest do
  # async: false because the LLMCall and ToolExec directives spawn Tasks
  # under the agent's TaskSupervisor; the Mimic stub on
  # ReqLLM.Generation.generate_text/3 must be visible from those Tasks,
  # and `set_mimic_global/0` is mutually exclusive with async tests.
  use JidoTest.Case, async: false
  use Mimic

  import Jido.AI.Test.ResponseFixtures

  alias Jido.AI.ReAct
  alias Jido.AI.Request
  alias Jido.AI.TestActions.TestAdd

  @model "anthropic:claude-haiku-4-5-20251001"

  defmodule MathAgent do
    @moduledoc false
    use Jido.Agent,
      name: "math",
      path: :state,
      slices: [
        {Jido.AI.ReAct,
         model: "anthropic:claude-haiku-4-5-20251001",
         tools: [Jido.AI.TestActions.TestAdd],
         system_prompt: "You are precise.",
         max_iterations: 4,
         max_tokens: 256,
         temperature: 0.0}
      ]
  end

  defmodule TestFailingTool do
    @moduledoc false
    use Jido.Action,
      name: "test_failing",
      description: "A tool that always returns {:error, _} — exercises the tool-error path.",
      schema: [reason: [type: :string, default: "nope"]]

    @impl true
    def run(_signal, _slice, _opts, _ctx), do: {:error, "explosion"}
  end

  defmodule FailingAgent do
    @moduledoc false
    use Jido.Agent,
      name: "failing",
      path: :state,
      slices: [
        {Jido.AI.ReAct,
         model: "anthropic:claude-haiku-4-5-20251001",
         tools: [Jido.AITest.TestFailingTool],
         system_prompt: "x",
         max_iterations: 4}
      ]
  end

  defmodule TightAgent do
    @moduledoc false
    use Jido.Agent,
      name: "tight",
      path: :state,
      slices: [
        {Jido.AI.ReAct,
         model: "anthropic:claude-haiku-4-5-20251001",
         tools: [Jido.AI.TestActions.TestAdd],
         system_prompt: "x",
         max_iterations: 1}
      ]
  end

  defmodule NoModelAgent do
    @moduledoc false
    use Jido.Agent,
      name: "no_model",
      path: :state,
      slices: [
        {Jido.AI.ReAct, tools: [Jido.AI.TestActions.TestAdd], max_iterations: 2}
      ]
  end

  setup :set_mimic_global
  setup :verify_on_exit!

  describe "slice attachment via slices:" do
    test "seeds slice config into state.ai", ctx do
      pid = start_test_server(ctx, MathAgent)
      ai = read_ai(pid)

      assert ai.status == :idle
      assert ai.model == @model
      assert ai.tools == [TestAdd]
      assert ai.system_prompt == "You are precise."
      assert ai.max_iterations == 4
      assert Keyword.fetch!(ai.llm_opts, :max_tokens) == 256
      assert Keyword.fetch!(ai.llm_opts, :temperature) == 0.0
    end
  end

  describe "ask/3 + await/2 happy path" do
    test "single-turn: final answer on the first LLM call", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert length(messages) == 2
        {:ok, final_answer_response("19")}
      end)

      pid = start_test_server(ctx, MathAgent)

      assert {:ok, %Request{id: id, sub_ref: ref, agent_pid: ^pid} = request} =
               Jido.AI.ask(pid, "What is 5 + 7 * 2?")

      assert is_binary(id)
      assert is_reference(ref)

      assert {:ok, "19"} = Jido.AI.await(request, timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :completed
      assert ai.result == "19"
      assert ai.error == nil
      assert ai.iteration == 1
      assert ai.request_id == id
    end

    test "ask_sync/3 pipes ask into await and returns the text", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, MathAgent)
      assert {:ok, "ok"} = Jido.AI.ask_sync(pid, "say ok", timeout: 1_000)
    end
  end

  describe "tool-using runs" do
    test "tool turn → tool exec → final answer turn", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert Enum.map(messages, & &1.role) == [:system, :user]
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert Enum.map(messages, & &1.role) == [:system, :user, :assistant, :tool]
        {:ok, final_answer_response("3")}
      end)

      pid = start_test_server(ctx, MathAgent)
      assert {:ok, request} = Jido.AI.ask(pid, "Add 1 and 2")
      assert {:ok, "3"} = Jido.AI.await(request, timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :completed
      assert ai.iteration == 2
      assert ai.pending_tool_calls == []
      assert ai.tool_results_received == []
    end

    test "appends a cycle warning when consecutive tool batches are identical", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 1}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 1}}])}
      end)

      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        send(test_pid, {:third_call_messages, messages})
        {:ok, final_answer_response("done")}
      end)

      pid = start_test_server(ctx, MathAgent)
      assert {:ok, request} = Jido.AI.ask(pid, "loop")
      assert {:ok, "done"} = Jido.AI.await(request, timeout: 1_000)

      assert_receive {:third_call_messages, messages}, 1_000

      texts =
        for msg <- messages,
            msg.role == :user,
            entry <- msg.content,
            text = Map.get(entry, :text),
            do: text

      assert Enum.any?(texts, &(&1 == ReAct.cycle_warning()))
    end

    test "tool errors are returned as JSON in tool.completed (not as :failed)", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_failing", %{"reason" => "boom"}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        tool_msg = Enum.find(messages, &(&1.role == :tool))
        assert tool_msg
        {:ok, final_answer_response("recovered")}
      end)

      pid = start_test_server(ctx, FailingAgent)
      assert {:ok, request} = Jido.AI.ask(pid, "use a broken tool")
      assert {:ok, "recovered"} = Jido.AI.await(request, timeout: 1_000)
    end
  end

  describe "max iterations" do
    test "settles :completed without a result when the cap is hit", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      pid = start_test_server(ctx, TightAgent)
      assert {:ok, request} = Jido.AI.ask(pid, "loop")
      assert {:ok, nil} = Jido.AI.await(request, timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :completed
      assert ai.result == nil
      assert ai.iteration == 1
    end
  end

  describe "failure paths" do
    test "settles slice to :failed when ReqLLM returns an error", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:error, :rate_limited}
      end)

      pid = start_test_server(ctx, MathAgent)
      assert {:ok, request} = Jido.AI.ask(pid, "boom")
      assert {:error, :rate_limited} = Jido.AI.await(request, timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :failed
      assert ai.error == :rate_limited
    end

    test "second ask while running returns {:error, :busy}", ctx do
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        send(test_pid, {:running, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        {:ok, final_answer_response("done")}
      end)

      pid = start_test_server(ctx, MathAgent)

      assert {:ok, first} = Jido.AI.ask(pid, "first")
      assert_receive {:running, task_pid}, 1_000

      assert {:error, %{details: %{reason: %{message: "busy"}}}} =
               Jido.AI.ask(pid, "second")

      send(task_pid, :release)
      assert {:ok, "done"} = Jido.AI.await(first, timeout: 1_000)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("third")}
      end)

      assert {:ok, third} = Jido.AI.ask(pid, "third")
      assert {:ok, "third"} = Jido.AI.await(third, timeout: 1_000)
    end

    test "await/2 returns {:error, :timeout} when no terminal signal arrives", ctx do
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        send(test_pid, {:running, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        {:ok, final_answer_response("late")}
      end)

      pid = start_test_server(ctx, MathAgent)
      assert {:ok, request} = Jido.AI.ask(pid, "stall")
      assert_receive {:running, task_pid}, 1_000

      assert {:error, :timeout} = Jido.AI.await(request, timeout: 50)

      send(task_pid, :release)
    end

    test "stale tool.completed signals are ignored", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, MathAgent)
      assert {:ok, request} = Jido.AI.ask(pid, "ok")
      assert {:ok, "ok"} = Jido.AI.await(request, timeout: 1_000)

      ai_before = read_ai(pid)

      stale =
        Jido.Signal.new!("ai.react.tool.completed", %{
          tool_call_id: "stale",
          name: "test_add",
          content: "{}",
          request_id: "different_request_id"
        })

      :ok = Jido.AgentServer.cast(pid, stale)
      # Force a round-trip — the state call is enqueued behind the cast
      # in the agent's mailbox, so when it returns the cast has already
      # been processed (or rejected by the action's staleness guard).
      {:ok, :ok} = Jido.AgentServer.state(pid, fn _ -> {:ok, :ok} end)

      assert read_ai(pid) == ai_before
    end

    test "{:error, :no_model} when neither slice config nor opts supply a model", ctx do
      pid = start_test_server(ctx, NoModelAgent)

      assert {:error, %{details: %{reason: %{message: "no_model"}}}} =
               Jido.AI.ask(pid, "anything")
    end
  end

  describe "per-call overrides" do
    test ":model and :system_prompt override the slice defaults", ctx do
      override_model = "anthropic:claude-sonnet-4-6"
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn model, messages, _opts ->
        send(test_pid, {:called_with, model, messages})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, MathAgent)

      assert {:ok, _req} =
               Jido.AI.ask(pid, "anything",
                 model: override_model,
                 system_prompt: "Override prompt."
               )

      assert_receive {:called_with, ^override_model, messages}, 1_000

      [system | _] = messages
      assert system.role == :system
      assert system.content |> hd() |> Map.get(:text) == "Override prompt."
    end

    test ":model from per-call opts is enough when slice has no model", ctx do
      expect(ReqLLM.Generation, :generate_text, fn model, _messages, _opts ->
        assert model == "openai:gpt-5"
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, NoModelAgent)
      assert {:ok, "ok"} = Jido.AI.ask_sync(pid, "anything", model: "openai:gpt-5")
    end

    test ":tools override replaces slice defaults", ctx do
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, opts ->
        tools = Keyword.fetch!(opts, :tools)
        send(test_pid, {:tools, tools})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, MathAgent)

      assert {:ok, _} =
               Jido.AI.ask_sync(pid, "anything", tools: [], timeout: 1_000)

      assert_receive {:tools, []}, 1_000
    end
  end

  defp read_ai(pid) do
    {:ok, ai} = Jido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.ai} end)
    ai
  end

  defp start_test_server(ctx, agent_module) do
    start_server(ctx, agent_module)
  end
end
