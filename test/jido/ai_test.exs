defmodule Jido.AITest do
  # async: false because the LLMCall and ToolExec directives spawn Tasks
  # under the agent's TaskSupervisor; the Mimic stub on
  # ReqLLM.Generation.generate_text/3 must be visible from those Tasks,
  # and `set_mimic_global/0` is mutually exclusive with async tests.
  use JidoTest.Case, async: false
  use Mimic

  import Jido.AI.Test.ResponseFixtures

  alias Jido.AI.ReAct

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

  describe "ask_sync/3 happy path" do
    test "slice config flows through to ReqLLM and the final answer is returned", ctx do
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn model, messages, opts ->
        send(test_pid, {:llm, model, messages, opts})
        {:ok, final_answer_response("19")}
      end)

      pid = start_test_server(ctx, MathAgent)
      assert {:ok, "19"} = Jido.AI.ask_sync(pid, "What is 5 + 7 * 2?", timeout: 1_000)

      # The slice's seeded config — model, system prompt, llm_opts
      # (with `max_tokens` / `temperature` folded by the slice's
      # config_schema transform) — must reach `ReqLLM.Generation` verbatim.
      assert_receive {:llm, model, messages, opts}, 1_000
      assert model == "anthropic:claude-haiku-4-5-20251001"
      assert opts[:max_tokens] == 256
      assert opts[:temperature] == 0.0

      [system, user] = messages
      assert system.role == :system
      assert system.content |> hd() |> Map.get(:text) == "You are precise."
      assert user.role == :user
    end
  end

  describe "ask/3 fire-and-forget" do
    test "returns {:ok, request_id} once the run is launched", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, MathAgent)

      assert {:ok, request_id} = Jido.AI.ask(pid, "What is 5 + 7 * 2?")
      assert is_binary(request_id)
      assert String.starts_with?(request_id, "req_")
    end

    test "caller can subscribe out-of-band and observe every intermediate signal", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("3")}
      end)

      pid = start_test_server(ctx, MathAgent)

      # Pure selector: project status + iteration. The default dispatch
      # `{:pid, target: self()}` sends `{:jido_subscription, sub_ref,
      # %{result: {:ok, projection}}}` to this process for every
      # non-:skip return.
      {:ok, sub_ref} =
        Jido.AgentServer.subscribe(pid, "ai.react.**", fn state ->
          ai = state.agent.state.ai

          if is_nil(ai.request_id) do
            :skip
          else
            {:ok, %{status: ai.status, iteration: ai.iteration}}
          end
        end)

      assert {:ok, request_id} = Jido.AI.ask(pid, "Add 1 and 2")
      assert is_binary(request_id)

      # We expect dispatches for: ask (running, 0) → llm.completed for
      # the tool turn (running, 1) → tool.completed (running, 1) →
      # llm.completed final (completed, 2). Order and exact counts
      # depend on signal interleaving; the important thing is we
      # observe both :running and :completed without await/2.
      assert_receive {:jido_subscription, ^sub_ref,
                      %{result: {:ok, %{status: :running}}}},
                     1_000

      assert_receive {:jido_subscription, ^sub_ref,
                      %{result: {:ok, %{status: :completed, iteration: 2}}}},
                     1_000

      :ok = Jido.AgentServer.unsubscribe(pid, sub_ref)
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
      assert {:ok, "3"} = Jido.AI.ask_sync(pid, "Add 1 and 2", timeout: 1_000)

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
      assert {:ok, "done"} = Jido.AI.ask_sync(pid, "loop", timeout: 1_000)

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
      assert {:ok, "recovered"} = Jido.AI.ask_sync(pid, "use a broken tool", timeout: 1_000)
    end
  end

  describe "max iterations" do
    test "settles :completed without a result when the cap is hit", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"a" => 1, "b" => 2}}])}
      end)

      pid = start_test_server(ctx, TightAgent)
      assert {:ok, nil} = Jido.AI.ask_sync(pid, "loop", timeout: 1_000)

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
      assert {:error, :rate_limited} = Jido.AI.ask_sync(pid, "boom", timeout: 1_000)

      ai = read_ai(pid)
      assert ai.status == :failed
      assert ai.error == :rate_limited
    end

    test "second ask while running returns the action's :busy chain error", ctx do
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

      task = Task.async(fn -> Jido.AI.ask_sync(pid, "first", timeout: 5_000) end)
      assert_receive {:running, llm_pid}, 1_000

      assert {:error, %{details: %{reason: %{message: "busy"}}}} =
               Jido.AI.ask(pid, "second")

      send(llm_pid, :release)
      assert {:ok, "done"} = Task.await(task, 1_000)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("third")}
      end)

      assert {:ok, "third"} = Jido.AI.ask_sync(pid, "third", timeout: 1_000)
    end

    test "ask_sync/3 returns {:error, :timeout} when no terminal signal arrives", ctx do
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

      task = Task.async(fn -> Jido.AI.ask_sync(pid, "stall", timeout: 50) end)
      assert_receive {:running, llm_pid}, 1_000
      assert {:error, :timeout} = Task.await(task, 1_000)

      send(llm_pid, :release)
    end

    test "stale tool.completed signals are ignored", ctx do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, MathAgent)
      assert {:ok, "ok"} = Jido.AI.ask_sync(pid, "ok", timeout: 1_000)

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

    test "ask returns :no_model chain error when neither slice config nor opts supply a model",
         ctx do
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

      assert {:ok, "ok"} =
               Jido.AI.ask_sync(pid, "anything",
                 model: override_model,
                 system_prompt: "Override prompt.",
                 timeout: 1_000
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
      assert {:ok, "ok"} = Jido.AI.ask_sync(pid, "anything", model: "openai:gpt-5", timeout: 1_000)
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

    test ":api_key in slice config llm_opts is propagated to ReqLLM", ctx do
      defmodule SliceKeyAgent do
        @moduledoc false
        use Jido.Agent,
          name: "slice_key",
          path: :state,
          slices: [
            {Jido.AI.ReAct,
             model: "anthropic:claude-haiku-4-5-20251001",
             tools: [],
             llm_opts: [api_key: "key-from-slice"]}
          ]
      end

      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, opts ->
        send(test_pid, {:api_key, Keyword.get(opts, :api_key)})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, SliceKeyAgent)
      assert {:ok, "ok"} = Jido.AI.ask_sync(pid, "anything", timeout: 1_000)
      assert_receive {:api_key, "key-from-slice"}, 1_000
    end

    test ":api_key per-call llm_opts overrides the slice default", ctx do
      defmodule SliceKeyOverrideAgent do
        @moduledoc false
        use Jido.Agent,
          name: "slice_key_override",
          path: :state,
          slices: [
            {Jido.AI.ReAct,
             model: "anthropic:claude-haiku-4-5-20251001",
             tools: [],
             llm_opts: [api_key: "slice-default"]}
          ]
      end

      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, opts ->
        send(test_pid, {:api_key, Keyword.get(opts, :api_key)})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, SliceKeyOverrideAgent)

      assert {:ok, "ok"} =
               Jido.AI.ask_sync(pid, "anything",
                 llm_opts: [api_key: "per-call-key"],
                 timeout: 1_000
               )

      assert_receive {:api_key, "per-call-key"}, 1_000
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
