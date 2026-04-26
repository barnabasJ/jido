defmodule Jido.Agent.Directive.CronCancel do
  @moduledoc """
  Cancel a previously registered cron job for this agent by job_id.

  ## Fields

  - `job_id` - The logical job id to cancel

  ## Examples

      %CronCancel{job_id: :heartbeat}
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              job_id: Zoi.any(description: "Logical cron job id within the agent")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for CronCancel."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Agent.Directive.CronCancel do
  @moduledoc false

  require Logger

  alias Jido.AgentServer
  alias Jido.AgentServer.Signal.CronCancelled
  alias Jido.AgentServer.State

  def exec(%{job_id: logical_id}, _input_signal, %State{} = state) do
    pid = Map.get(state.cron_jobs, logical_id)
    monitor_ref = Map.get(state.cron_monitors, logical_id)
    proposed_specs = Map.delete(state.cron_specs, logical_id)

    cancel_io(pid, monitor_ref)

    case AgentServer.persist_cron_specs(state, proposed_specs) do
      :ok ->
        emit_cancellation(state, logical_id, pid, monitor_ref)

      {:error, {:invalid_checkpoint, _} = reason} ->
        AgentServer.emit_cron_telemetry_event(state, :persist_failure, %{
          job_id: logical_id,
          reason: reason
        })

        emit_cancellation(state, logical_id, pid, monitor_ref)

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to persist cron cancellation for #{inspect(logical_id)}: #{inspect(reason)}"
        )

        AgentServer.emit_cron_telemetry_event(state, :persist_failure, %{
          job_id: logical_id,
          reason: reason
        })
    end

    :ok
  end

  defp cancel_io(pid, monitor_ref) do
    if is_pid(pid) and Process.alive?(pid) do
      Jido.Scheduler.cancel(pid)
    end

    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end

    :ok
  end

  defp emit_cancellation(%State{} = state, logical_id, pid, monitor_ref) do
    signal =
      CronCancelled.new!(
        %{
          job_id: logical_id,
          pid: pid,
          monitor_ref: monitor_ref
        },
        source: "/agent/#{state.id}"
      )

    _ = AgentServer.cast(self(), signal)

    Logger.debug("AgentServer #{state.id} cancelled cron job #{inspect(logical_id)}")

    AgentServer.emit_cron_telemetry_event(state, :cancel, %{job_id: logical_id})
  end
end
