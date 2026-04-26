defmodule JidoTest.AgentServer.CronTickDeliveryTest do
  @moduledoc """
  Regression test for issue #136: Directive.Cron executor silently fails
  because cast(agent_id, signal) rejects string IDs via resolve_server/1.

  These tests verify that cron ticks actually reach the agent and update state,
  not just that jobs register successfully.
  """
  use JidoTest.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Jido.Agent.Directive
  alias Jido.AgentServer
  alias Jido.Signal

  # ---------------------------------------------------------------------------
  # Test Actions
  # ---------------------------------------------------------------------------

  defmodule TickCountAction do
    @moduledoc false
    use Jido.Action, name: "tick_count", schema: []

    def run(_signal, slice, _opts, _ctx) do
      slice = if is_map(slice), do: slice, else: %{}
      count = Map.get(slice, :tick_count, 0)
      {:ok, Map.put(slice, :tick_count, count + 1), []}
    end
  end

  defmodule RegisterCronAction do
    @moduledoc false
    use Jido.Action, name: "register_cron", schema: []

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      cron_expr = Map.get(params, :cron)
      job_id = Map.get(params, :job_id)

      tick_signal = Signal.new!("cron.tick", %{}, source: "/test/cron")
      directive = Directive.cron(cron_expr, tick_signal, job_id: job_id)
      {:ok, slice, [directive]}
    end
  end

  # ---------------------------------------------------------------------------
  # Test Agent
  # ---------------------------------------------------------------------------

  defmodule CronTickAgent do
    @moduledoc false
    use Jido.Agent,
      name: "cron_tick_agent",
      path: :domain,
      schema: [
        tick_count: [type: :integer, default: 0]
      ]

    def signal_routes(_ctx) do
      [
        {"register_cron", RegisterCronAction},
        {"cron.tick", TickCountAction}
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "cron tick delivery (issue #136 regression)" do
    test "cron tick actually delivers signal and updates agent state", %{jido: jido} do
      # Use extended 7-field cron: fires every second
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: CronTickAgent,
          id: unique_id("cron-tick"),
          jido: jido
        )

      register_signal =
        Signal.new!("register_cron", %{job_id: :tick_test, cron: "* * * * * * *"},
          source: "/test"
        )

      :ok = AgentServer.cast(pid, register_signal)

      # Wait for the cron job to register
      await_state_value(pid, fn s -> if Map.has_key?(s.cron_jobs, :tick_test), do: true end)

      # The actual regression: before the fix, ticks would silently fail
      # because cast(string_id, signal) was rejected by resolve_server/1.
      # With the fix, ticks should deliver and increment tick_count.
      await_state_value(
        pid,
        fn s ->
          tc = s.agent.state.domain.tick_count
          if tc > 0, do: tc
        end,
        timeout: 5_000
      )

      GenServer.stop(pid)
    end

    test "cast to PID succeeds where cast to string ID would fail", %{jido: jido} do
      # This test directly verifies the root cause: string IDs are rejected
      id = unique_id("cron-cast")
      {:ok, pid} = AgentServer.start_link(agent_module: CronTickAgent, id: id, jido: jido)

      tick_signal = Signal.new!("cron.tick", %{}, source: "/test/cron")

      # Cast with PID should succeed (the fix)
      assert :ok = AgentServer.cast(pid, tick_signal)

      await_state_value(pid, fn s ->
        if s.agent.state.domain.tick_count == 1, do: true
      end)

      # Cast with string ID should fail (the original bug)
      assert {:error, {:invalid_server, _}} =
               AgentServer.call(id, tick_signal, fn s -> {:ok, s.agent} end)

      GenServer.stop(pid)
    end

    test "multiple cron ticks accumulate state changes", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: CronTickAgent,
          id: unique_id("cron-multi"),
          jido: jido
        )

      register_signal =
        Signal.new!("register_cron", %{job_id: :multi_tick, cron: "* * * * * * *"},
          source: "/test"
        )

      :ok = AgentServer.cast(pid, register_signal)

      await_state_value(pid, fn s -> if Map.has_key?(s.cron_jobs, :multi_tick), do: true end)

      # Wait for at least 2 ticks to confirm accumulation
      await_state_value(
        pid,
        fn s ->
          tc = s.agent.state.domain.tick_count
          if tc >= 2, do: tc
        end,
        timeout: 5_000
      )

      GenServer.stop(pid)
    end
  end
end
