defmodule Jido.Agent.Directive.Cron do
  @moduledoc """
  Register or update a recurring cron job for this agent.

  The job is owned by the agent's `id` and identified within that agent
  by `job_id`. On each tick, the scheduler sends `message` (or `signal`)
  back to the agent via `Jido.AgentServer.cast/2`.

  ## Fields

  - `job_id` - Logical id within the agent (for upsert/cancel). Auto-generated if nil.
  - `cron` - Cron expression string (e.g., "* * * * *", "@daily", "*/5 * * * *")
  - `message` - Signal or message to send on each tick
  - `timezone` - Optional timezone identifier (default: UTC)

  ## Examples

      # Every minute, send a tick signal
      %Cron{cron: "* * * * *", message: tick_signal, job_id: :heartbeat}

      # Daily at midnight, send a cleanup signal
      %Cron{cron: "@daily", message: cleanup_signal, job_id: :daily_cleanup}

      # Every 5 minutes with timezone
      %Cron{cron: "*/5 * * * *", message: check_signal, job_id: :check, timezone: "America/New_York"}
  """

  require Logger

  alias Jido.AgentServer
  alias Jido.AgentServer.{CronRuntimeSpec, State}

  @schema Zoi.struct(
            __MODULE__,
            %{
              job_id:
                Zoi.any(description: "Logical cron job id within the agent")
                |> Zoi.optional(),
              cron: Zoi.any(description: "Cron expression (e.g. \"* * * * *\", \"@daily\")"),
              message: Zoi.any(description: "Signal or message to send on each tick"),
              timezone:
                Zoi.any(description: "Timezone identifier (optional)")
                |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Cron."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @typedoc false
  @type io_result :: %{
          job_id: term(),
          pid: pid(),
          monitor_ref: reference(),
          cron_spec: map(),
          runtime_spec: term()
        }

  # Pure I/O for cron registration. Validates the expression, spawns
  # the scheduler job, monitors it, and persists the new spec map.
  # Returns the data the cascade callback
  # (`maybe_track_cron_registered/2`) needs to install in the runtime
  # maps. Does **not** mutate `%AgentServer.State{}` — per ADR 0019 §1,
  # runtime field writes flow through the cascade.
  @doc false
  @spec register_io(State.t(), term(), term(), term() | nil, term() | nil) ::
          {:ok, io_result()} | {:error, term()}
  def register_io(%State{} = state, cron_expr, message, logical_id, tz) do
    logical_id = logical_id || make_ref()

    with {:ok, cron_spec} <- Jido.Scheduler.validate_and_build_cron_spec(cron_expr, message, tz),
         runtime_spec =
           CronRuntimeSpec.dynamic(
             cron_spec.cron_expression,
             cron_spec.message,
             cron_spec.timezone
           ),
         {:ok, pid} <- AgentServer.start_runtime_cron_job(state, logical_id, runtime_spec) do
      proposed_specs = Map.put(state.cron_specs, logical_id, cron_spec)

      case AgentServer.persist_cron_specs(state, proposed_specs) do
        :ok ->
          {:ok, build_io_result(logical_id, pid, cron_spec, runtime_spec)}

        {:error, {:invalid_checkpoint, _} = reason} ->
          AgentServer.emit_cron_telemetry_event(state, :persist_failure, %{
            job_id: logical_id,
            cron_expression: cron_spec.cron_expression,
            reason: reason
          })

          {:ok, build_io_result(logical_id, pid, cron_spec, runtime_spec)}

        {:error, reason} ->
          Jido.Scheduler.cancel(pid)

          AgentServer.emit_cron_telemetry_event(state, :persist_failure, %{
            job_id: logical_id,
            cron_expression: cron_spec.cron_expression,
            reason: reason
          })

          {:error, {:persist_failed, reason}}
      end
    end
  end

  defp build_io_result(logical_id, pid, cron_spec, runtime_spec) do
    %{
      job_id: logical_id,
      pid: pid,
      monitor_ref: Process.monitor(pid),
      cron_spec: cron_spec,
      runtime_spec: runtime_spec
    }
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Agent.Directive.Cron do
  @moduledoc false

  require Logger

  alias Jido.AgentServer
  alias Jido.AgentServer.Signal.CronRegistered

  def exec(
        %{cron: cron_expr, message: message, job_id: logical_id, timezone: tz},
        _input_signal,
        state
      ) do
    case Jido.Agent.Directive.Cron.register_io(state, cron_expr, message, logical_id, tz) do
      {:ok, io_result} ->
        signal =
          CronRegistered.new!(
            %{
              job_id: io_result.job_id,
              pid: io_result.pid,
              monitor_ref: io_result.monitor_ref,
              cron_spec: io_result.cron_spec,
              runtime_spec: io_result.runtime_spec
            },
            source: "/agent/#{state.id}"
          )

        _ = AgentServer.cast(self(), signal)

        Logger.debug(
          "AgentServer #{state.id} registered cron job #{inspect(io_result.job_id)}: #{cron_expr}"
        )

        AgentServer.emit_cron_telemetry_event(state, :register, %{
          job_id: io_result.job_id,
          cron_expression: cron_expr
        })

        :ok

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to register cron job #{inspect(logical_id)}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
