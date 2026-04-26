defmodule JidoTest.Support.SchedulerIntegrationHarness do
  @moduledoc false

  alias Jido.Agent.Directive
  alias Jido.AgentServer
  alias Jido.Signal
  alias Jido.Scheduler

  defmodule TickAction do
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

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      cron_expr = Map.get(params, :cron)
      job_id = Map.get(params, :job_id)
      timezone = Map.get(params, :timezone)
      message = Map.get(params, :message, Signal.new!(%{type: "cron.tick", source: "/test"}))

      directive = Directive.cron(cron_expr, message, job_id: job_id, timezone: timezone)
      {:ok, slice, [directive]}
    end
  end

  defmodule CancelCronAction do
    @moduledoc false
    use Jido.Action, name: "cancel_cron", schema: []

    def run(%Jido.Signal{data: %{job_id: job_id}}, slice, _opts, _ctx) do
      {:ok, slice, [Directive.cron_cancel(job_id)]}
    end
  end

  defmodule CronAgent do
    @moduledoc false
    use Jido.Agent,
      name: "scheduler_integration_agent",
      path: :domain,
      schema: [
        tick_count: [type: :integer, default: 0],
        ticks: [type: {:list, :any}, default: []]
      ]

    def signal_routes(_ctx) do
      [
        {"register_cron", RegisterCronAction},
        {"cancel_cron", CancelCronAction},
        {"cron.tick", TickAction}
      ]
    end
  end

  defmodule ScheduledCronAgent do
    @moduledoc false
    use Jido.Agent,
      name: "scheduler_integration_scheduled_agent",
      path: :domain,
      schema: [
        tick_count: [type: :integer, default: 0],
        ticks: [type: {:list, :any}, default: []]
      ],
      schedules: [
        {"* * * * * * *", "cron.tick", job_id: :scheduled_heartbeat}
      ]

    def signal_routes(_ctx) do
      [
        {"cron.tick", TickAction}
      ]
    end
  end

  def start_cron_agent(context, opts \\ []) do
    JidoTest.Case.start_server(
      context,
      CronAgent,
      Keyword.put_new(opts, :id, JidoTest.Case.unique_id("scheduler-integration"))
    )
  end

  def start_scheduled_agent(context, opts \\ []) do
    JidoTest.Case.start_server(
      context,
      ScheduledCronAgent,
      Keyword.put_new(opts, :id, JidoTest.Case.unique_id("scheduler-scheduled"))
    )
  end

  def scheduled_job_id do
    {:agent_schedule, "scheduler_integration_scheduled_agent", :scheduled_heartbeat}
  end

  def unique_table(prefix \\ "scheduler_integration") do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  def cleanup_storage_tables(table) do
    Enum.each([:"#{table}_checkpoints", :"#{table}_threads", :"#{table}_thread_meta"], fn t ->
      try do
        :ets.delete(t)
      rescue
        _ -> :ok
      end
    end)
  end

  def checkpoint_key(agent_module, manager, key) do
    {agent_module, {manager, key}}
  end

  def stage_cron_specs(agent, cron_specs) when is_map(cron_specs) do
    Scheduler.attach_staged_cron_specs(agent, cron_specs)
  end

  def register_cron(pid, cron_expr, opts \\ []) do
    message = Keyword.get(opts, :message, Signal.new!(%{type: "cron.tick", source: "/test"}))

    signal =
      Signal.new!(%{
        type: "register_cron",
        source: "/test",
        data: %{
          cron: cron_expr,
          job_id: Keyword.get(opts, :job_id),
          timezone: Keyword.get(opts, :timezone),
          message: message
        }
      })

    AgentServer.cast(pid, signal)
  end

  def cancel_cron(pid, job_id) do
    signal =
      Signal.new!(%{
        type: "cancel_cron",
        source: "/test",
        data: %{job_id: job_id}
      })

    AgentServer.cast(pid, signal)
  end

  @doc """
  Wait for `job_id` to be registered (and alive) in `state.cron_jobs`.

  Subscribe-based per ADR 0021 — see `JidoTest.AgentWait.await_state_value/3`.
  """
  def wait_for_job(pid, job_id, opts \\ []) do
    JidoTest.AgentWait.await_state_value(
      pid,
      fn s ->
        case Map.get(s.cron_jobs, job_id) do
          job_pid when is_pid(job_pid) ->
            if Process.alive?(job_pid), do: job_pid, else: nil

          _ ->
            nil
        end
      end,
      opts
    )
  end

  @doc """
  Wait for the agent's domain `tick_count` to reach `count`.

  Subscribe-based per ADR 0021 — each `cron.tick` triggers a pipeline
  whose post-state the subscription evaluates. No polling.
  """
  def wait_for_tick_count(pid, count, opts \\ []) do
    JidoTest.AgentWait.await_state_value(
      pid,
      fn s ->
        tick_count = s.agent.state.domain.tick_count
        if tick_count >= count, do: tick_count, else: nil
      end,
      opts
    )
  end

  def tick_count(pid) do
    {:ok, count} =
      AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.tick_count} end)

    count
  end

  def ticks(pid) do
    {:ok, ticks} =
      AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.ticks} end)

    ticks
  end
end
