defmodule JidoTest.AgentServer.CronIntegrationTest do
  use JidoTest.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :integration
  @moduletag capture_log: true

  alias Jido.Agent.Directive
  alias Jido.AgentServer
  alias Jido.Signal

  defmodule CronCountAction do
    @moduledoc false
    use Jido.Action, name: "cron_count", schema: []

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      count = Map.get(slice, :tick_count, 0)
      ticks = Map.get(slice, :ticks, [])
      {:ok, %{tick_count: count + 1, ticks: ticks ++ [params]}, []}
    end
  end

  defmodule RegisterCronAction do
    @moduledoc false
    use Jido.Action, name: "register_cron", schema: []

    def run(%Jido.Signal{data: params}, _slice, _opts, _ctx) do
      cron_expr = Map.get(params, :cron)
      job_id = Map.get(params, :job_id)
      message = Map.get(params, :message, Signal.new!(%{type: "cron.tick", source: "/test"}))
      timezone = Map.get(params, :timezone)

      directive = Directive.cron(cron_expr, message, job_id: job_id, timezone: timezone)
      {:ok, %{}, [directive]}
    end
  end

  defmodule CancelCronAction do
    @moduledoc false
    use Jido.Action, name: "cancel_cron", schema: []

    def run(%Jido.Signal{data: %{job_id: job_id}}, _slice, _opts, _ctx) do
      {:ok, %{}, [Directive.cron_cancel(job_id)]}
    end
  end

  defmodule CronTestAgent do
    @moduledoc false
    use Jido.Agent,
      name: "cron_test_agent",
      path: :domain,
      schema: [
        tick_count: [type: :integer, default: 0],
        ticks: [type: {:list, :any}, default: []]
      ]

    def signal_routes(_ctx) do
      [
        {"register_cron", RegisterCronAction},
        {"cancel_cron", CancelCronAction},
        {"cron.tick", CronCountAction}
      ]
    end
  end

  describe "cron job registration" do
    test "agent can register a cron job", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-1", jido: jido)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{
            job_id: :heartbeat,
            cron: "* * * * *"
          }
        })

      :ok = AgentServer.cast(pid, register_signal)

      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :heartbeat) end)

      assert is_pid(job_pid)
      assert Process.alive?(job_pid)

      GenServer.stop(pid)
    end

    test "agent can register multiple cron jobs", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-2", jido: jido)

      for {job_id, cron_expr} <- [heartbeat: "* * * * *", daily: "@daily", hourly: "@hourly"] do
        register_signal =
          Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: job_id, cron: cron_expr}
          })

        :ok = AgentServer.cast(pid, register_signal)
      end

      cron_jobs =
        await_state_value(pid, fn s -> if map_size(s.cron_jobs) == 3, do: s.cron_jobs end)

      assert Map.has_key?(cron_jobs, :heartbeat)
      assert Map.has_key?(cron_jobs, :daily)
      assert Map.has_key?(cron_jobs, :hourly)

      for {_id, job_pid} <- cron_jobs do
        assert is_pid(job_pid)
        assert Process.alive?(job_pid)
      end

      GenServer.stop(pid)
    end

    test "registering same job_id updates existing job (upsert)", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-3", jido: jido)

      register_signal1 =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :updatable, cron: "* * * * *"}
        })

      :ok = AgentServer.cast(pid, register_signal1)

      first_job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :updatable) end)
      assert is_pid(first_job_pid)

      register_signal2 =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :updatable, cron: "@hourly"}
        })

      :ok = AgentServer.cast(pid, register_signal2)

      cron_jobs =
        await_state_value(pid, fn s ->
          if s.cron_jobs[:updatable] && s.cron_jobs[:updatable] != first_job_pid,
            do: s.cron_jobs
        end)

      assert map_size(cron_jobs) == 1
      second_job_pid = cron_jobs[:updatable]
      assert is_pid(second_job_pid)

      refute first_job_pid == second_job_pid

      GenServer.stop(pid)
    end

    test "failed upsert preserves the existing runtime job and durable spec", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: CronTestAgent,
          id: "cron-test-upsert-invalid",
          jido: jido
        )

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :stable, cron: "* * * * *"}
        })

      :ok = AgentServer.cast(pid, register_signal)

      %{job_pid: job_pid, cron_spec: cron_spec} =
        await_state_value(pid, fn s ->
          if Map.has_key?(s.cron_jobs, :stable) and Map.has_key?(s.cron_specs, :stable) do
            %{job_pid: s.cron_jobs[:stable], cron_spec: s.cron_specs[:stable]}
          end
        end)

      invalid_update_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :stable, cron: "not-a-cron"}
        })

      :ok = AgentServer.cast(pid, invalid_update_signal)

      cron_spec_after =
        await_state_value(pid, fn s ->
          if s.cron_jobs[:stable] == job_pid and s.cron_specs[:stable] == cron_spec do
            s.cron_specs[:stable]
          end
        end)

      assert Process.alive?(job_pid)
      assert cron_spec_after.cron_expression == "* * * * *"

      GenServer.stop(pid)
    end

    test "invalid dynamic cron input logs and preserves the agent", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: CronTestAgent,
          id: "cron-test-invalid-type",
          jido: jido
        )

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_type, cron: 123}
        })

      log =
        capture_log(fn ->
          assert {:ok, _agent} =
                   AgentServer.call(pid, register_signal, fn s -> {:ok, s.agent} end)

          {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
            AgentServer.state(pid, fn s ->
              {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
            end)

          refute Map.has_key?(cron_jobs, :invalid_type)
          refute Map.has_key?(cron_specs, :invalid_type)
        end)

      assert Process.alive?(pid)
      assert log =~ "failed to register cron job :invalid_type"

      GenServer.stop(pid)
    end

    test "rejects non-durable cron messages during registration", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: CronTestAgent,
          id: "cron-test-invalid-message",
          jido: jido
        )

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_message, cron: "* * * * *", message: {:notify, self()}}
        })

      log =
        capture_log(fn ->
          assert {:ok, _agent} =
                   AgentServer.call(pid, register_signal, fn s -> {:ok, s.agent} end)

          {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
            AgentServer.state(pid, fn s ->
              {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
            end)

          refute Map.has_key?(cron_jobs, :invalid_message)
          refute Map.has_key?(cron_specs, :invalid_message)
        end)

      assert log =~ "invalid_message"

      GenServer.stop(pid)
    end

    test "cron job with timezone", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-4", jido: jido)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{
            job_id: :timezone_test,
            cron: "0 9 * * *",
            timezone: "Etc/UTC"
          }
        })

      :ok = AgentServer.cast(pid, register_signal)

      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :timezone_test) end)
      assert is_pid(job_pid)

      GenServer.stop(pid)
    end

    test "invalid cron directive is isolated and agent survives", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-4b", jido: jido)

      ref = Process.monitor(pid)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{
            job_id: :invalid_cron,
            cron: "definitely-not-a-cron"
          }
        })

      :ok = AgentServer.cast(pid, register_signal)

      eventually(fn -> Process.alive?(pid) end)

      {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
        AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
        end)

      refute Map.has_key?(cron_jobs, :invalid_cron)
      refute Map.has_key?(cron_specs, :invalid_cron)
      refute_received {:DOWN, ^ref, :process, ^pid, _}

      GenServer.stop(pid)
    end

    test "invalid timezone directive is isolated and agent survives", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-4c", jido: jido)

      ref = Process.monitor(pid)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{
            job_id: :invalid_tz,
            cron: "0 9 * * *",
            timezone: "Invalid/Nowhere"
          }
        })

      :ok = AgentServer.cast(pid, register_signal)

      eventually(fn -> Process.alive?(pid) end)

      {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
        AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
        end)

      refute Map.has_key?(cron_jobs, :invalid_tz)
      refute Map.has_key?(cron_specs, :invalid_tz)
      refute_received {:DOWN, ^ref, :process, ^pid, _}

      GenServer.stop(pid)
    end

    test "auto-generates job_id if not provided", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-5", jido: jido)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{cron: "* * * * *"}
        })

      :ok = AgentServer.cast(pid, register_signal)

      cron_jobs =
        await_state_value(pid, fn s -> if map_size(s.cron_jobs) == 1, do: s.cron_jobs end)

      [job_id] = Map.keys(cron_jobs)
      assert is_reference(job_id)

      GenServer.stop(pid)
    end
  end

  describe "runtime failure isolation and recovery" do
    test "abnormal cron job death does not kill agent and job restarts", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-9a", jido: jido)

      server_ref = Process.monitor(pid)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :restartable, cron: "* * * * *"}
        })

      :ok = AgentServer.cast(pid, register_signal)

      original_job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :restartable) end)
      assert is_pid(original_job_pid)
      assert Process.alive?(original_job_pid)

      Process.exit(original_job_pid, :kill)

      restarted_job_pid =
        await_state_value(
          pid,
          fn s ->
            new_pid = Map.get(s.cron_jobs, :restartable)
            if is_pid(new_pid) and new_pid != original_job_pid and Process.alive?(new_pid),
              do: new_pid
          end,
          timeout: 6_000
        )

      refute restarted_job_pid == original_job_pid
      assert Process.alive?(pid)
      refute_received {:DOWN, ^server_ref, :process, ^pid, _}

      GenServer.stop(pid)
    end

    test "cancel removes durable spec even when runtime pid is already gone", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-9b", jido: jido)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :gone_runtime, cron: "* * * * *"}
        })

      :ok = AgentServer.cast(pid, register_signal)

      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :gone_runtime) end)
      assert is_pid(job_pid)

      Process.exit(job_pid, :shutdown)

      await_state_value(
        pid,
        fn s ->
          if not Map.has_key?(s.cron_jobs, :gone_runtime) and
               Map.has_key?(s.cron_specs, :gone_runtime),
             do: true
        end,
        timeout: 2_000
      )

      cancel_signal =
        Signal.new!(%{
          type: "cancel_cron",
          source: "/test",
          data: %{job_id: :gone_runtime}
        })

      :ok = AgentServer.cast(pid, cancel_signal)

      await_state_value(
        pid,
        fn s ->
          if not Map.has_key?(s.cron_jobs, :gone_runtime) and
               not Map.has_key?(s.cron_specs, :gone_runtime),
             do: true
        end,
        timeout: 2_000
      )

      GenServer.stop(pid)
    end
  end

  describe "cron job cancellation" do
    test "agent can cancel a cron job", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-6", jido: jido)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :cancellable, cron: "* * * * *"}
        })

      :ok = AgentServer.cast(pid, register_signal)

      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :cancellable) end)
      assert is_pid(job_pid)
      assert Process.alive?(job_pid)

      cancel_signal =
        Signal.new!(%{
          type: "cancel_cron",
          source: "/test",
          data: %{job_id: :cancellable}
        })

      :ok = AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s ->
        if not Map.has_key?(s.cron_jobs, :cancellable), do: true
      end)

      eventually(fn -> not Process.alive?(job_pid) end)

      GenServer.stop(pid)
    end

    test "cancelling non-existent job is safe", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-7", jido: jido)

      cancel_signal =
        Signal.new!(%{
          type: "cancel_cron",
          source: "/test",
          data: %{job_id: :nonexistent}
        })

      :ok = AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s -> if map_size(s.cron_jobs) == 0, do: true end)

      GenServer.stop(pid)
    end

    test "can cancel and re-register same job_id", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-8", jido: jido)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :toggle, cron: "* * * * *"}
        })

      :ok = AgentServer.cast(pid, register_signal)

      await_state_value(pid, fn s -> if Map.has_key?(s.cron_jobs, :toggle), do: true end)

      cancel_signal =
        Signal.new!(%{
          type: "cancel_cron",
          source: "/test",
          data: %{job_id: :toggle}
        })

      :ok = AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s -> if not Map.has_key?(s.cron_jobs, :toggle), do: true end)

      register_signal2 =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :toggle, cron: "@hourly"}
        })

      :ok = AgentServer.cast(pid, register_signal2)

      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :toggle) end)
      assert is_pid(job_pid)

      GenServer.stop(pid)
    end
  end

  describe "cleanup on agent termination" do
    test "cron jobs are cleaned up when agent stops normally", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-10", jido: jido)

      register_signal =
        Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :cleanup_test, cron: "* * * * *"}
        })

      :ok = AgentServer.cast(pid, register_signal)

      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :cleanup_test) end)
      assert is_pid(job_pid)
      assert Process.alive?(job_pid)

      GenServer.stop(pid)

      eventually(fn -> not Process.alive?(job_pid) end)
    end

    test "multiple cron jobs are all cleaned up on termination", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-11", jido: jido)

      job_ids = [:job1, :job2, :job3]

      for job_id <- job_ids do
        register_signal =
          Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: job_id, cron: "* * * * *"}
          })

        :ok = AgentServer.cast(pid, register_signal)
      end

      cron_jobs =
        await_state_value(pid, fn s -> if map_size(s.cron_jobs) == 3, do: s.cron_jobs end)

      job_pids = Enum.map(job_ids, fn id -> cron_jobs[id] end)

      for job_pid <- job_pids do
        assert is_pid(job_pid)
        assert Process.alive?(job_pid)
      end

      GenServer.stop(pid)

      for job_pid <- job_pids do
        eventually(fn -> not Process.alive?(job_pid) end)
      end
    end
  end

  describe "job scoping" do
    test "different agents can use same job_id without collision", %{jido: jido} do
      {:ok, pid1} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-12a", jido: jido)

      {:ok, pid2} =
        AgentServer.start_link(agent_module: CronTestAgent, id: "cron-test-12b", jido: jido)

      for pid <- [pid1, pid2] do
        register_signal =
          Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: :shared_name, cron: "* * * * *"}
          })

        :ok = AgentServer.cast(pid, register_signal)
      end

      job_pid1 = await_state_value(pid1, fn s -> Map.get(s.cron_jobs, :shared_name) end)
      job_pid2 = await_state_value(pid2, fn s -> Map.get(s.cron_jobs, :shared_name) end)

      refute job_pid1 == job_pid2
      assert Process.alive?(job_pid1)
      assert Process.alive?(job_pid2)

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end
end
