defmodule Jido.Directives.AsyncTaskTest do
  use ExUnit.Case, async: true

  alias Jido.AgentServer.{DirectiveExec, Options, State}
  alias Jido.Directives
  alias Jido.Signal

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  setup do
    jido = :"async_task_test_#{System.unique_integer([:positive])}"
    {:ok, jido_pid} = Jido.start_link(name: jido)

    on_exit(fn ->
      if Process.alive?(jido_pid) do
        try do
          GenServer.stop(jido_pid, :normal, 100)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    %{jido: jido}
  end

  defmodule TestAgent do
    @moduledoc false

    use Jido.Agent

    agent do
      name "async_task_test_agent"
      path(:domain)
      schema value: [type: :any, default: nil]
    end
  end

  defmodule Work do
    @moduledoc false

    @spec ok(test_pid :: pid()) :: {:ok, map()}
    def ok(test_pid) do
      send(test_pid, :ok_work_ran)
      {:ok, %{answer: 42}}
    end

    @spec error(test_pid :: pid()) :: {:error, atom()}
    def error(test_pid) do
      send(test_pid, :error_work_ran)
      {:error, :boom}
    end

    @spec plain(test_pid :: pid()) :: String.t()
    def plain(test_pid) do
      send(test_pid, :plain_work_ran)
      "plain-result"
    end

    @spec custom_signal() :: Signal.t()
    def custom_signal do
      Signal.new!("custom.done", %{value: 7}, source: "/work/custom")
    end

    @spec multiple_signals() :: {:signals, [Signal.t()]}
    def multiple_signals do
      {:signals,
       [
         Signal.new!("custom.one", %{index: 1}, source: "/work/multi"),
         Signal.new!("custom.two", %{index: 2}, source: "/work/multi")
       ]}
    end

    @spec raise_error() :: no_return()
    def raise_error do
      raise ArgumentError, "bad input"
    end

    @spec throw_value() :: no_return()
    def throw_value do
      throw(:thrown_value)
    end

    @spec exit_value() :: no_return()
    def exit_value do
      exit(:exited_value)
    end
  end

  defp input_signal do
    Signal.new!("test.async_task", %{request_id: "req_1"}, source: "/test")
  end

  defp state(jido) do
    agent = TestAgent.new()
    {:ok, opts} = Options.new(%{agent_module: TestAgent, id: "async-task-agent", jido: jido})
    {:ok, state} = State.from_options(opts, TestAgent, agent)
    state
  end

  defp spawn_agent_stub(target_pid) do
    spawn_link(fn -> forward(target_pid) end)
  end

  defp forward(target_pid) do
    receive do
      {:"$gen_cast", {:signal, signal}} ->
        send(target_pid, {:cast, signal})
        forward(target_pid)

      {:run, fun, from} ->
        send(from, {:run_done, fun.()})
        forward(target_pid)

      _other ->
        forward(target_pid)
    end
  end

  defp run_in(agent_pid, fun) do
    send(agent_pid, {:run, fun, self()})

    receive do
      {:run_done, result} -> result
    after
      1_000 -> :timeout
    end
  end

  test "wraps {:ok, result} in the configured success signal", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)

    directive =
      Directives.async_task({Work, :ok, [test_pid]},
        success_type: "work.completed",
        error_type: "work.failed",
        payload: %{request_id: "req_1"}
      )

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive :ok_work_ran, 1_000
    assert_receive {:cast, signal}, 1_000
    assert signal.type == "work.completed"
    assert signal.source == "/agent/async-task-agent/async_task"
    assert signal.data == %{request_id: "req_1", result: %{answer: 42}}
  end

  test "wraps {:error, reason} in the configured error signal", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)

    directive =
      Directives.async_task({Work, :error, [test_pid]},
        success_type: "work.completed",
        error_type: "work.failed",
        payload: %{request_id: "req_2"}
      )

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive :error_work_ran, 1_000
    assert_receive {:cast, signal}, 1_000
    assert signal.type == "work.failed"
    assert signal.data == %{request_id: "req_2", reason: :boom}
  end

  test "wraps plain return values as success results", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)

    directive = Directives.async_task({Work, :plain, [test_pid]}, success_type: "work.completed")

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive :plain_work_ran, 1_000
    assert_receive {:cast, signal}, 1_000
    assert signal.type == "work.completed"
    assert signal.data == %{result: "plain-result"}
  end

  test "casts a signal returned by the MFA without wrapping it", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)
    directive = Directives.async_task({Work, :custom_signal, []})

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "custom.done"
    assert signal.source == "/work/custom"
    assert signal.data == %{value: 7}
  end

  test "casts every signal returned by {:signals, signals}", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)
    directive = Directives.async_task({Work, :multiple_signals, []})

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive {:cast, first}, 1_000
    assert_receive {:cast, second}, 1_000
    assert first.type == "custom.one"
    assert first.data == %{index: 1}
    assert second.type == "custom.two"
    assert second.data == %{index: 2}
  end

  test "passes runtime context to unary function work", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)

    directive =
      Directives.async_task(
        fn context ->
          {:ok, %{agent_id: context.agent_id, input_type: context.input_signal.type}}
        end,
        success_type: "work.context"
      )

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "work.context"

    assert signal.data == %{
             result: %{agent_id: "async-task-agent", input_type: "test.async_task"}
           }
  end

  test "converts raised exceptions into error signals", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)
    directive = Directives.async_task({Work, :raise_error, []}, error_type: "work.failed")

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "work.failed"
    assert signal.data.kind == :error
    assert %ArgumentError{message: "bad input"} = signal.data.reason
  end

  test "converts thrown values into error signals", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)
    directive = Directives.async_task({Work, :throw_value, []}, error_type: "work.failed")

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "work.failed"
    assert signal.data == %{kind: :throw, reason: :thrown_value}
  end

  test "converts exits into error signals", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)
    directive = Directives.async_task({Work, :exit_value, []}, error_type: "work.failed")

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "work.failed"
    assert signal.data == %{kind: :exit, reason: :exited_value}
  end

  test "does not crash when the reply target is unavailable", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)

    directive =
      Directives.async_task({Work, :ok, [test_pid]},
        success_type: "work.completed",
        target: :missing_async_task_target
      )

    :ok = run_in(agent, fn -> DirectiveExec.exec(directive, input_signal(), state(jido)) end)

    assert_receive :ok_work_ran, 1_000
    refute_receive {:cast, _signal}, 100
  end
end
