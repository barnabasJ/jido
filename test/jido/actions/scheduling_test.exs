defmodule JidoTest.Actions.SchedulingTest do
  use ExUnit.Case, async: true

  alias Jido.Actions.Scheduling
  alias Jido.Agent.Directive
  alias Jido.Signal

  defp sig(type, data) do
    Signal.new!(%{type: type, source: "/test", data: data})
  end

  describe "ScheduleSignal" do
    test "creates schedule directive with signal" do
      data = %{
        delay_ms: 5000,
        signal_type: "work.check",
        payload: %{attempt: 1},
        source: "/scheduler"
      }

      {:ok, result, [directive]} =
        Scheduling.ScheduleSignal.run(sig("schedule_signal", data), %{}, %{}, %{})

      assert result == %{scheduled_for_ms: 5000, signal_type: "work.check"}
      assert %Directive.Schedule{} = directive
      assert directive.delay_ms == 5000
      assert directive.message.type == "work.check"
      assert directive.message.data == %{attempt: 1}
    end

    test "uses default source" do
      data = %{delay_ms: 1000, signal_type: "ping", payload: %{}, source: "/scheduler"}

      {:ok, _result, [directive]} =
        Scheduling.ScheduleSignal.run(sig("schedule_signal", data), %{}, %{}, %{})

      assert directive.message.source == "/scheduler"
    end
  end

  describe "ScheduleTimeout" do
    test "creates schedule directive for timeout" do
      data = %{timeout_ms: 30_000, timeout_id: :work_deadline, signal_type: "agent.timeout"}

      {:ok, result, [directive]} =
        Scheduling.ScheduleTimeout.run(sig("schedule_timeout", data), %{}, %{}, %{})

      assert result == %{timeout_set: :work_deadline, expires_in_ms: 30_000}
      assert %Directive.Schedule{} = directive
      assert directive.delay_ms == 30_000
      assert directive.message.type == "agent.timeout"
      assert directive.message.data == %{timeout_id: :work_deadline}
    end

    test "uses default timeout_id" do
      data = %{timeout_ms: 5000, timeout_id: :default, signal_type: "agent.timeout"}

      {:ok, result, [_directive]} =
        Scheduling.ScheduleTimeout.run(sig("schedule_timeout", data), %{}, %{}, %{})

      assert result.timeout_set == :default
    end
  end

  describe "ScheduleCron" do
    test "creates cron directive" do
      data = %{
        cron: "* * * * *",
        job_id: :heartbeat,
        signal_type: "agent.heartbeat",
        payload: %{},
        timezone: nil
      }

      {:ok, result, [directive]} =
        Scheduling.ScheduleCron.run(sig("schedule_cron", data), %{}, %{}, %{})

      assert result == %{cron_scheduled: "* * * * *", job_id: :heartbeat}
      assert %Directive.Cron{} = directive
      assert directive.cron == "* * * * *"
      assert directive.job_id == :heartbeat
      assert directive.message.type == "agent.heartbeat"
    end

    test "includes timezone when provided" do
      data = %{
        cron: "0 9 * * *",
        job_id: :daily,
        signal_type: "daily.task",
        payload: %{},
        timezone: "America/New_York"
      }

      {:ok, _result, [directive]} =
        Scheduling.ScheduleCron.run(sig("schedule_cron", data), %{}, %{}, %{})

      assert directive.timezone == "America/New_York"
    end
  end

  describe "CancelCron" do
    test "creates cron cancel directive" do
      data = %{job_id: :heartbeat}

      {:ok, result, [directive]} =
        Scheduling.CancelCron.run(sig("cancel_cron", data), %{}, %{}, %{})

      assert result == %{cancelled_job: :heartbeat}
      assert %Directive.CronCancel{} = directive
      assert directive.job_id == :heartbeat
    end
  end
end
