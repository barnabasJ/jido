defmodule JidoTest.Integration.SchedulerIntegrationTest do
  @moduledoc """
  Scheduler integration tests for invasive runtime failure scenarios.

  Target only with:

      mix test --only scheduler_integration test/jido/integration/scheduler_integration_test.exs
  """

  use JidoTest.Case, async: false

  import ExUnit.CaptureLog
  import JidoTest.Support.SchedulerIntegrationHarness

  alias Jido.AgentServer
  alias Jido.Signal
  alias JidoTest.Support.FailingTimeZoneDatabase

  @moduletag :integration
  @moduletag :scheduler_integration
  @moduletag capture_log: true
  @moduletag timeout: 20_000

  defmodule PluginTickAction do
    @moduledoc false
    use Jido.Action, name: "plugin_tick", schema: []

    def run(_signal, slice, _opts, _ctx) do
      count = Map.get(slice, :tick_count, 0)
      ticks = Map.get(slice, :ticks, [])
      {:ok, %{tick_count: count + 1, ticks: ticks ++ [%{source: :plugin_schedule}]}, []}
    end
  end

  defmodule ScheduledPlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "scheduler_integration_plugin",
      path: :scheduler_integration_plugin,
      actions: [PluginTickAction],
      schedules: [
        {"* * * * * * *", PluginTickAction}
      ]
  end

  defmodule PluginScheduledAgent do
    @moduledoc false
    use Jido.Agent,
      name: "scheduler_integration_plugin_agent",
      path: :domain,
      schema: [
        tick_count: [type: :integer, default: 0],
        ticks: [type: {:list, :any}, default: []]
      ],
      plugins: [ScheduledPlugin]
  end

  defp plugin_job_id do
    {:plugin_schedule, :scheduler_integration_plugin, PluginTickAction}
  end

  describe "runtime scheduler failures" do
    test "cron job enters retry mode during time zone database failure and resumes after recovery",
         context do
      on_exit(fn ->
        Application.put_env(:jido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
      end)

      pid = start_cron_agent(context, id: unique_id("scheduler-retry"))

      assert :ok =
               register_cron(pid, "* * * * * * *",
                 job_id: :heartbeat,
                 timezone: "America/New_York"
               )

      job_pid = wait_for_job(pid, :heartbeat, timeout: 5_000)
      wait_for_tick_count(pid, 1, timeout: 5_000)

      server_ref = Process.monitor(pid)

      # Simulate time zone database failure
      Application.put_env(:jido, :time_zone_database, FailingTimeZoneDatabase)

      eventually(fn -> Process.alive?(pid) end, timeout: 2_000)

      eventually(fn -> Process.alive?(job_pid) and :sys.get_state(job_pid).retrying? end,
        timeout: 5_000
      )

      {:ok, %{heartbeat_pid: heartbeat_pid, baseline: baseline}} =
        AgentServer.state(pid, fn s ->
          {:ok,
           %{
             heartbeat_pid: s.cron_jobs[:heartbeat],
             baseline: s.agent.state.domain.tick_count
           }}
        end)

      assert heartbeat_pid == job_pid
      assert Process.alive?(job_pid)

      # Restore working database
      Application.put_env(:jido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)

      eventually(fn -> Process.alive?(job_pid) and not :sys.get_state(job_pid).retrying? end,
        timeout: 5_000
      )

      wait_for_tick_count(pid, baseline + 1, timeout: 8_000)

      refute_received {:DOWN, ^server_ref, :process, ^pid, _reason}
    end

    test "non-durable cron payload is isolated and later cron registrations still work",
         context do
      pid = start_cron_agent(context, id: unique_id("scheduler-bad-message"))
      server_ref = Process.monitor(pid)

      bad_message =
        Signal.new!("cron.tick", %{reply_to: self(), kind: :bad_message}, source: "/test")

      good_message =
        Signal.new!("cron.tick", %{kind: :good_message}, source: "/test")

      log =
        capture_log(fn ->
          assert :ok =
                   register_cron(pid, "* * * * * * *",
                     job_id: :bad_message,
                     message: bad_message
                   )

          assert :ok =
                   register_cron(pid, "* * * * * * *",
                     job_id: :good_message,
                     message: good_message
                   )

          good_job_pid = wait_for_job(pid, :good_message, timeout: 5_000)
          assert Process.alive?(good_job_pid)

          await_state_value(
            pid,
            fn s ->
              ticks = s.agent.state.domain.ticks
              count = Enum.count(ticks, &(&1[:kind] == :good_message))
              if count >= 1, do: count
            end,
            timeout: 5_000
          )
        end)

      {:ok, snapshot} =
        AgentServer.state(pid, fn s ->
          {:ok,
           %{
             cron_jobs: s.cron_jobs,
             cron_specs_keys: Map.keys(s.cron_specs)
           }}
        end)

      refute Map.has_key?(snapshot.cron_jobs, :bad_message)
      refute :bad_message in snapshot.cron_specs_keys
      assert is_pid(snapshot.cron_jobs[:good_message])
      assert Process.alive?(snapshot.cron_jobs[:good_message])
      refute_received {:DOWN, ^server_ref, :process, ^pid, _reason}
      assert log =~ "failed to register cron job :bad_message"
    end

    test "restarting one dynamic cron job does not disrupt sibling jobs", context do
      pid = start_cron_agent(context, id: unique_id("scheduler-siblings"))
      server_ref = Process.monitor(pid)

      alpha_message = Signal.new!("cron.tick", %{job: :alpha}, source: "/test")
      beta_message = Signal.new!("cron.tick", %{job: :beta}, source: "/test")

      assert :ok =
               register_cron(pid, "* * * * * * *",
                 job_id: :alpha,
                 message: alpha_message
               )

      assert :ok =
               register_cron(pid, "* * * * * * *",
                 job_id: :beta,
                 message: beta_message
               )

      alpha_job_pid = wait_for_job(pid, :alpha, timeout: 5_000)
      beta_job_pid = wait_for_job(pid, :beta, timeout: 5_000)

      await_state_value(
        pid,
        fn s ->
          ticks = s.agent.state.domain.ticks

          if Enum.any?(ticks, &(&1[:job] == :alpha)) and
               Enum.any?(ticks, &(&1[:job] == :beta)) do
            true
          end
        end,
        timeout: 5_000
      )

      beta_baseline =
        ticks(pid)
        |> Enum.count(&(&1[:job] == :beta))

      Process.exit(alpha_job_pid, :kill)

      # The DOWN handler restarts the cron job synchronously; the next
      # `cron.tick` (≤1s for "* * * * * * *") wakes our subscription so
      # the selector sees the new pid.
      restarted_alpha_pid =
        await_state_value(
          pid,
          fn s ->
            new_alpha_pid = s.cron_jobs[:alpha]

            if is_pid(new_alpha_pid) and new_alpha_pid != alpha_job_pid and
                 Process.alive?(new_alpha_pid) do
              new_alpha_pid
            end
          end,
          timeout: 6_000
        )

      assert Process.alive?(beta_job_pid)

      {:ok, beta_pid} = AgentServer.state(pid, fn s -> {:ok, s.cron_jobs[:beta]} end)
      assert beta_pid == beta_job_pid
      assert Process.alive?(restarted_alpha_pid)

      await_state_value(
        pid,
        fn s ->
          count = Enum.count(s.agent.state.domain.ticks, &(&1[:job] == :beta))
          if count >= beta_baseline + 1, do: count
        end,
        timeout: 5_000
      )

      refute_received {:DOWN, ^server_ref, :process, ^pid, _reason}
    end
  end

  describe "declarative schedule behavior" do
    test "agent schedules are runtime-only and do not populate durable cron_specs", context do
      pid = start_scheduled_agent(context, id: unique_id("scheduler-declarative"))

      job_id = scheduled_job_id()
      job_pid = wait_for_job(pid, job_id, timeout: 5_000)

      assert Process.alive?(job_pid)
      eventually(fn -> tick_count(pid) >= 1 end, timeout: 5_000)

      {:ok, snapshot} =
        AgentServer.state(pid, fn s ->
          {:ok, %{job_pid: s.cron_jobs[job_id], cron_specs: s.cron_specs}}
        end)

      assert snapshot.job_pid == job_pid
      assert snapshot.cron_specs == %{}
    end

    test "agent schedules restart after abnormal scheduler death", context do
      pid = start_scheduled_agent(context, id: unique_id("scheduler-declarative-restart"))

      job_id = scheduled_job_id()
      original_job_pid = wait_for_job(pid, job_id, timeout: 5_000)
      assert Process.alive?(original_job_pid)

      Process.exit(original_job_pid, :kill)

      restarted_job_pid =
        await_state_value(
          pid,
          fn s ->
            new_job_pid = s.cron_jobs[job_id]

            if is_pid(new_job_pid) and new_job_pid != original_job_pid and
                 Process.alive?(new_job_pid) do
              new_job_pid
            end
          end,
          timeout: 6_000
        )

      assert is_pid(restarted_job_pid)
      assert Process.alive?(restarted_job_pid)
    end
  end

  describe "plugin schedule behavior" do
    test "plugin schedules are runtime-only and deliver ticks", context do
      pid = start_server(context, PluginScheduledAgent, id: unique_id("scheduler-plugin-runtime"))

      job_id = plugin_job_id()
      job_pid = wait_for_job(pid, job_id, timeout: 5_000)

      assert Process.alive?(job_pid)

      eventually(
        fn ->
          tick_count(pid) >= 1 and Enum.any?(ticks(pid), &(&1[:source] == :plugin_schedule))
        end,
        timeout: 5_000
      )

      {:ok, snapshot} =
        AgentServer.state(pid, fn s ->
          {:ok, %{job_pid: s.cron_jobs[job_id], cron_specs: s.cron_specs}}
        end)

      assert snapshot.job_pid == job_pid
      assert snapshot.cron_specs == %{}
    end

    test "plugin schedules restart after abnormal scheduler death", context do
      pid = start_server(context, PluginScheduledAgent, id: unique_id("scheduler-plugin-restart"))

      job_id = plugin_job_id()
      original_job_pid = wait_for_job(pid, job_id, timeout: 5_000)
      assert Process.alive?(original_job_pid)

      Process.exit(original_job_pid, :kill)

      restarted_job_pid =
        await_state_value(
          pid,
          fn s ->
            new_job_pid = s.cron_jobs[job_id]

            if is_pid(new_job_pid) and new_job_pid != original_job_pid and
                 Process.alive?(new_job_pid) do
              new_job_pid
            end
          end,
          timeout: 6_000
        )

      assert is_pid(restarted_job_pid)
      assert Process.alive?(restarted_job_pid)
    end
  end
end
