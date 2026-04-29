defmodule JidoTest.Agent.SchedulesIntegrationTest do
  use JidoTest.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  defmodule TickAction do
    use Jido.Action

    action do
      name "tick"
      schema []
    end

    def run(_signal, slice, _opts, _ctx) do
      count = Map.get(slice, :tick_count, 0)
      {:ok, %{tick_count: count + 1}, []}
    end
  end

  defmodule ScheduledAgent do
    use Jido.Agent

    agent do
      name "scheduled_agent"
      path :domain
      schema tick_count: [type: :integer, default: 0]
    end

    schedules do
      schedule "* * * * * * *", "agent.tick", job_id: :tick
    end

    signal_routes do
      route "agent.tick", TickAction
    end
  end

  defmodule MultiScheduleAgent do
    use Jido.Agent

    agent do
      name "multi_schedule_agent"
      path :domain
      schema tick_count: [type: :integer, default: 0]
    end

    schedules do
      schedule "* * * * *", "heartbeat.tick", job_id: :heartbeat
      schedule "@daily", "cleanup.run", job_id: :cleanup, timezone: "America/New_York"
    end

    signal_routes do
      route "heartbeat.tick", TickAction
      route "cleanup.run", TickAction
    end
  end

  defmodule NoScheduleAgent do
    use Jido.Agent

    agent do
      name "no_schedule_agent"
      path :domain
      schema tick_count: [type: :integer, default: 0]
    end
  end

  describe "agent with schedules" do
    test "Info.plugin_schedules/1 typespec includes plugin and agent schedule specs" do
      module = Jido.Dsl.Agent.Info
      beam_path = :code.which(module) |> List.to_string()

      {:ok, {_module, [abstract_code: {:raw_abstract_v1, abstract_code}]}} =
        :beam_lib.chunks(String.to_charlist(beam_path), [:abstract_code])

      {{:plugin_schedules, 1}, [spec]} =
        Enum.find_value(abstract_code, fn
          {:attribute, _line, :spec, {{:plugin_schedules, 1}, _} = spec} -> spec
          _other -> nil
        end)

      rendered =
        :plugin_schedules
        |> Code.Typespec.spec_to_quoted(spec)
        |> Macro.to_string()

      assert String.contains?(rendered, "Jido.Plugin.Schedules.schedule_spec()")
      assert String.contains?(rendered, "Jido.Agent.Schedules.schedule_spec()")
      assert String.contains?(rendered, "|")
    end

    test "plugin_schedules/0 includes agent schedules" do
      schedules = Jido.Dsl.Agent.Info.plugin_schedules(ScheduledAgent)

      agent_schedules =
        Enum.filter(schedules, fn spec ->
          match?({:agent_schedule, _, _}, spec.job_id)
        end)

      assert agent_schedules != []
    end

    test "agent schedules have correct job_id namespacing" do
      schedules = Jido.Dsl.Agent.Info.plugin_schedules(ScheduledAgent)

      agent_schedule =
        Enum.find(schedules, fn spec ->
          match?({:agent_schedule, _, _}, spec.job_id)
        end)

      assert agent_schedule.job_id == {:agent_schedule, "scheduled_agent", :tick}
    end

    test "agent schedules have correct signal_type" do
      schedules = Jido.Dsl.Agent.Info.plugin_schedules(ScheduledAgent)

      agent_schedule =
        Enum.find(schedules, fn spec ->
          match?({:agent_schedule, _, _}, spec.job_id)
        end)

      assert agent_schedule.signal_type == "agent.tick"
    end

    test "agent with no schedules has no agent schedules in plugin_schedules" do
      schedules = Jido.Dsl.Agent.Info.plugin_schedules(NoScheduleAgent)

      agent_schedules =
        Enum.filter(schedules, fn spec ->
          match?({:agent_schedule, _, _}, spec.job_id)
        end)

      assert agent_schedules == []
    end

    test "multiple schedules are all included" do
      schedules = Jido.Dsl.Agent.Info.plugin_schedules(MultiScheduleAgent)

      agent_schedules =
        Enum.filter(schedules, fn spec ->
          match?({:agent_schedule, _, _}, spec.job_id)
        end)

      assert length(agent_schedules) == 2

      signal_types = Enum.map(agent_schedules, & &1.signal_type) |> Enum.sort()
      assert signal_types == ["cleanup.run", "heartbeat.tick"]
    end
  end

  describe "agent schedule tick delivery" do
    test "schedule tick delivers signal and updates state", %{jido: jido} do
      pid = start_server(%{jido: jido}, ScheduledAgent)

      await_state_value(
        pid,
        fn s ->
          tc = s.agent.state.domain.tick_count
          if tc > 0, do: tc
        end,
        timeout: 5_000
      )
    end
  end
end
