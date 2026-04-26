defmodule JidoTest.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Telemetry

  defmodule TestAgent do
    @moduledoc false
    use Jido.Agent,
      name: "telemetry_test_agent",
      path: :domain,
      schema: [
        counter: [type: :integer, default: 0]
      ]

    def signal_routes(_ctx), do: []
  end

  defp with_telemetry_env(temp_value, fun) when is_function(fun, 0) do
    previous =
      case Application.fetch_env(:jido, :telemetry) do
        {:ok, value} -> {:ok, value}
        :error -> :error
      end

    try do
      case temp_value do
        :delete -> Application.delete_env(:jido, :telemetry)
        value -> Application.put_env(:jido, :telemetry, value)
      end

      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:jido, :telemetry, value)
        :error -> Application.delete_env(:jido, :telemetry)
      end
    end
  end

  describe "setup/0" do
    test "attaches telemetry handlers idempotently" do
      assert :ok = Telemetry.setup()
      assert :ok = Telemetry.setup()
    end
  end

  describe "handle_event/4" do
    test "handles agent cmd start event" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :cmd, :start],
                 %{system_time: 123},
                 %{agent_id: "test", agent_module: TestAgent, action: :test},
                 nil
               )
    end

    test "handles agent cmd stop event" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :cmd, :stop],
                 %{duration: 1000},
                 %{agent_id: "test", agent_module: TestAgent, directive_count: 0},
                 nil
               )
    end

    test "handles agent cmd exception event" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :cmd, :exception],
                 %{duration: 1000},
                 %{agent_id: "test", agent_module: TestAgent, error: :some_error},
                 nil
               )
    end

    test "handles strategy init events" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :init, :start],
                 %{system_time: 123},
                 %{agent_id: "test", strategy: TestAgent},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :init, :stop],
                 %{duration: 1000},
                 %{agent_id: "test", strategy: TestAgent},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :init, :exception],
                 %{duration: 1000},
                 %{agent_id: "test", strategy: TestAgent, error: :err},
                 nil
               )
    end

    test "handles strategy cmd events" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :cmd, :start],
                 %{system_time: 123},
                 %{agent_id: "test", strategy: TestAgent},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :cmd, :stop],
                 %{duration: 1000},
                 %{agent_id: "test", strategy: TestAgent, directive_count: 2},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :cmd, :exception],
                 %{duration: 1000},
                 %{agent_id: "test", strategy: TestAgent, error: :err},
                 nil
               )
    end

    test "handles strategy tick events" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :tick, :start],
                 %{system_time: 123},
                 %{agent_id: "test", strategy: TestAgent},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :tick, :stop],
                 %{duration: 1000},
                 %{agent_id: "test", strategy: TestAgent},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent, :strategy, :tick, :exception],
                 %{duration: 1000},
                 %{agent_id: "test", strategy: TestAgent, error: :err},
                 nil
               )
    end

    test "handles agent_server signal events" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :signal, :start],
                 %{system_time: 123},
                 %{agent_id: "test", signal_type: "test.signal"},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :signal, :stop],
                 %{duration: 1000},
                 %{agent_id: "test", signal_type: "test.signal", directive_count: 1},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :signal, :exception],
                 %{duration: 1000},
                 %{agent_id: "test", signal_type: "test.signal", error: :err},
                 nil
               )
    end

    test "does not emit signal summary logs at the default info level" do
      log =
        with_telemetry_env(:delete, fn ->
          capture_log(fn ->
            assert :ok =
                     Telemetry.handle_event(
                       [:jido, :agent_server, :signal, :stop],
                       %{duration: 1_000},
                       %{
                         agent_id: "test",
                         signal_type: "test.signal",
                         directive_count: 2,
                         directive_types: %{"Emit" => 1, "Schedule" => 1}
                       },
                       nil
                     )
          end)
        end)

      assert log == ""
    end

    test "includes directive type summary in signal logs when debug logging is enabled" do
      log =
        with_telemetry_env([log_level: :debug], fn ->
          capture_log(fn ->
            assert :ok =
                     Telemetry.handle_event(
                       [:jido, :agent_server, :signal, :stop],
                       %{duration: 1_000},
                       %{
                         agent_id: "test",
                         signal_type: "test.signal",
                         directive_count: 2,
                         directive_types: %{"Emit" => 1, "Schedule" => 1}
                       },
                       nil
                     )
          end)
        end)

      assert log =~ "[signal] type=test.signal directives=2"
      assert log =~ "Emit=1"
      assert log =~ "Schedule=1"
    end

    test "handles agent_server directive events" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :directive, :start],
                 %{system_time: 123},
                 %{agent_id: "test", directive_type: "Emit"},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :directive, :stop],
                 %{duration: 1000},
                 %{agent_id: "test", directive_type: "Emit", result: :ok},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :directive, :exception],
                 %{duration: 1000},
                 %{agent_id: "test", directive_type: "Emit", error: :err},
                 nil
               )
    end

    test "handles agent_server cron events" do
      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :cron, :register],
                 %{},
                 %{agent_id: "test", job_id: :job, cron_expression: "* * * * *"},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :cron, :cancel],
                 %{},
                 %{agent_id: "test", job_id: :job},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :cron, :restart_scheduled],
                 %{},
                 %{agent_id: "test", job_id: :job, reason: :killed, delay_ms: 500},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :cron, :restart_succeeded],
                 %{},
                 %{agent_id: "test", job_id: :job, cron_expression: "* * * * *"},
                 nil
               )

      assert :ok =
               Telemetry.handle_event(
                 [:jido, :agent_server, :cron, :persist_failure],
                 %{},
                 %{agent_id: "test", job_id: :job, reason: :boom},
                 nil
               )
    end
  end
end
