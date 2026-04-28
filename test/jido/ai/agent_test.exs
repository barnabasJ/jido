defmodule Jido.AI.AgentTest do
  # async: false because the LLMCall and ToolExec directives spawn Tasks
  # under the agent's TaskSupervisor; the Mimic stub on
  # ReqLLM.Generation.generate_text/3 must be visible from those Tasks,
  # and `set_mimic_global/0` is mutually exclusive with async tests.
  use JidoTest.Case, async: false
  use Mimic

  import Jido.AI.Test.ResponseFixtures

  alias Jido.AI.{Request, Slice}
  alias Jido.AI.TestActions.TestAdd

  @model "anthropic:claude-haiku-4-5-20251001"

  defmodule MathAgent do
    @moduledoc false
    use Jido.AI.Agent,
      name: "math",
      description: "Test math agent.",
      model: "anthropic:claude-haiku-4-5-20251001",
      tools: [Jido.AI.TestActions.TestAdd],
      system_prompt: "You are precise.",
      max_iterations: 4,
      max_tokens: 256,
      temperature: 0.0
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
    use Jido.AI.Agent,
      name: "failing",
      model: "anthropic:claude-haiku-4-5-20251001",
      tools: [Jido.AI.AgentTest.TestFailingTool],
      system_prompt: "x",
      max_iterations: 4
  end

  defmodule TightAgent do
    @moduledoc false
    use Jido.AI.Agent,
      name: "tight",
      model: "anthropic:claude-haiku-4-5-20251001",
      tools: [Jido.AI.TestActions.TestAdd],
      system_prompt: "x",
      max_iterations: 1
  end

  setup :set_mimic_global
  setup :verify_on_exit!

  describe "macro-generated module" do
    test "exposes ask/3, await/2, ask_sync/3 and __ai_defaults__/0" do
      for {fun, arity} <- [{:ask, 3}, {:await, 2}, {:ask_sync, 3}, {:__ai_defaults__, 0}] do
        assert function_exported?(MathAgent, fun, arity)
      end
    end

    test "captures the macro defaults at compile time" do
      defaults = MathAgent.__ai_defaults__()

      assert defaults.model == @model
      assert defaults.tools == [TestAdd]
      assert defaults.system_prompt == "You are precise."
      assert defaults.max_iterations == 4
      assert defaults.llm_opts == [max_tokens: 256, temperature: 0.0]
    end

    test "the agent's own slice IS the AI slice — path :ai, no plugin indirection" do
      assert Slice.path() == :ai
      assert MathAgent.path() == :ai
      # Plugin list is whatever the framework default plugins are; the AI
      # slice is NOT among them.
      refute Slice in Enum.map(MathAgent.plugin_specs(), & &1.module)
    end

    test "seeds the slice with the schema's defaults" do
      agent = MathAgent.new()

      assert agent.state.ai == %{
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
  end

  describe "ask/3 + await/2 happy path" do
    test "single-turn: final answer on the first LLM call", %{jido: jido} do
      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert length(messages) == 2
        {:ok, final_answer_response("19")}
      end)

      pid = start_test_server(jido, MathAgent)

      assert {:ok, %Request{id: id, sub_ref: ref, agent_pid: ^pid} = request} =
               MathAgent.ask(pid, "What is 5 + 7 * 2?")

      assert is_binary(id)
      assert is_reference(ref)

      assert {:ok, "19"} = MathAgent.await(request, timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :completed
      assert ai.result == "19"
      assert ai.error == nil
      assert ai.iteration == 1
      assert ai.request_id == id
    end

    test "ask_sync/3 pipes ask into await and returns the text", %{jido: jido} do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(jido, MathAgent)
      assert {:ok, "ok"} = MathAgent.ask_sync(pid, "say ok", timeout: 1_000)
    end
  end

  describe "tool-using runs" do
    test "tool turn → tool exec → final answer turn", %{jido: jido} do
      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert Enum.map(messages, & &1.role) == [:system, :user]
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert Enum.map(messages, & &1.role) == [:system, :user, :assistant, :tool]
        {:ok, final_answer_response("3")}
      end)

      pid = start_test_server(jido, MathAgent)
      assert {:ok, request} = MathAgent.ask(pid, "Add 1 and 2")
      assert {:ok, "3"} = MathAgent.await(request, timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :completed
      assert ai.iteration == 2
      assert ai.pending_tool_calls == []
      assert ai.tool_results_received == []
    end

    test "two parallel tool calls fan-in to one next LLMCall", %{jido: jido} do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok,
         tool_call_response([
           {"test_add", %{"a" => 1, "b" => 2}},
           {"test_add", %{"a" => 10, "b" => 20}}
         ])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        # system + user + assistant (with 2 tool calls) + 2 tool results
        assert Enum.map(messages, & &1.role) == [:system, :user, :assistant, :tool, :tool]
        {:ok, final_answer_response("3 and 30")}
      end)

      pid = start_test_server(jido, MathAgent)
      assert {:ok, request} = MathAgent.ask(pid, "Add 1+2 and 10+20")
      assert {:ok, "3 and 30"} = MathAgent.await(request, timeout: 1_000)
    end

    test "appends a cycle warning when consecutive tool batches are identical", %{jido: jido} do
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

      pid = start_test_server(jido, MathAgent)
      assert {:ok, request} = MathAgent.ask(pid, "loop")
      assert {:ok, "done"} = MathAgent.await(request, timeout: 1_000)

      assert_receive {:third_call_messages, messages}, 1_000

      texts =
        for msg <- messages,
            msg.role == :user,
            entry <- msg.content,
            text = Map.get(entry, :text),
            do: text

      assert Enum.any?(texts, &(&1 == Slice.cycle_warning()))
    end

    test "tool errors are returned as JSON in tool.completed (not as :failed)", %{jido: jido} do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_failing", %{"reason" => "boom"}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        tool_msg = Enum.find(messages, &(&1.role == :tool))
        assert tool_msg
        {:ok, final_answer_response("recovered")}
      end)

      pid = start_test_server(jido, FailingAgent)
      assert {:ok, request} = FailingAgent.ask(pid, "use a broken tool")
      assert {:ok, "recovered"} = FailingAgent.await(request, timeout: 1_000)
    end
  end

  describe "max iterations" do
    test "settles :completed without a result when the cap is hit", %{jido: jido} do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      pid = start_test_server(jido, TightAgent)
      assert {:ok, request} = TightAgent.ask(pid, "loop")
      assert {:ok, nil} = TightAgent.await(request, timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :completed
      assert ai.result == nil
      assert ai.iteration == 1
    end
  end

  describe "failure paths" do
    test "settles slice to :failed when ReqLLM returns an error", %{jido: jido} do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:error, :rate_limited}
      end)

      pid = start_test_server(jido, MathAgent)
      assert {:ok, request} = MathAgent.ask(pid, "boom")
      assert {:error, :rate_limited} = MathAgent.await(request, timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :failed
      assert ai.error == :rate_limited
    end

    test "second ask while running returns {:error, :busy}", %{jido: jido} do
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

      pid = start_test_server(jido, MathAgent)

      assert {:ok, first} = MathAgent.ask(pid, "first")
      assert_receive {:running, task_pid}, 1_000

      assert {:error, :busy} = MathAgent.ask(pid, "second")

      send(task_pid, :release)
      assert {:ok, "done"} = MathAgent.await(first, timeout: 1_000)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("third")}
      end)

      assert {:ok, third} = MathAgent.ask(pid, "third")
      assert {:ok, "third"} = MathAgent.await(third, timeout: 1_000)
    end

    test "await/2 returns {:error, :timeout} when no terminal signal arrives", %{jido: jido} do
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

      pid = start_test_server(jido, MathAgent)
      assert {:ok, request} = MathAgent.ask(pid, "stall")
      assert_receive {:running, task_pid}, 1_000

      assert {:error, :timeout} = MathAgent.await(request, timeout: 50)

      send(task_pid, :release)
    end

    test "stale tool.completed signals are ignored", %{jido: jido} do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(jido, MathAgent)
      assert {:ok, request} = MathAgent.ask(pid, "ok")
      assert {:ok, "ok"} = MathAgent.await(request, timeout: 1_000)

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
  end

  describe "per-call overrides" do
    test ":model and :system_prompt override the macro defaults", %{jido: jido} do
      override_model = "anthropic:claude-sonnet-4-6"
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn model, messages, _opts ->
        send(test_pid, {:called_with, model, messages})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(jido, MathAgent)

      assert {:ok, _req} =
               MathAgent.ask(pid, "anything",
                 model: override_model,
                 system_prompt: "Override prompt."
               )

      assert_receive {:called_with, ^override_model, messages}, 1_000

      [system | _] = messages
      assert system.role == :system
      assert system.content |> hd() |> Map.get(:text) == "Override prompt."
    end
  end

  defp read_ai(pid) do
    {:ok, ai} = Jido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.ai} end)
    ai
  end

  defp start_test_server(jido, agent_module) do
    {:ok, pid} =
      Jido.AgentServer.start_link(
        agent_module: agent_module,
        id: JidoTest.Case.unique_id(),
        jido: jido
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    pid
  end
end
