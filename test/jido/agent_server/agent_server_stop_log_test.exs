defmodule JidoTest.AgentServerStopLogTest do
  use JidoTest.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.AgentServer
  alias Jido.Directives
  alias Jido.Signal

  defmodule StopTestAction do
    @moduledoc false
    use Jido.Action

    action do
      name "stop_test"
      schema []
    end

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, [%Directives.Stop{reason: :normal}]}
    end
  end

  defmodule TestAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "test_agent"
    end

    signal_routes do
      route "stop_test", StopTestAction
    end
  end

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :warning)

    on_exit(fn ->
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  test "Stop directive with normal reason logs warning", %{jido: jido} do
    log =
      capture_log(fn ->
        {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, jido: jido)
        ref = Process.monitor(pid)

        signal = Signal.new!("stop_test", %{}, source: "/test")
        AgentServer.cast(pid, signal)

        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      end)

    assert log =~ "received {:stop, :normal"
    assert log =~ "This is a HARD STOP"
  end
end
