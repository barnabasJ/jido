defmodule Jido.Exec.Compensation do
  @moduledoc """
  Handles error compensation logic for Jido actions.

  This module provides functionality to execute compensation actions when
  an action fails, if the action implements the `on_error/4` callback and
  has compensation enabled in its metadata.
  """
  use Private

  alias Jido.Action.Error
  alias Jido.Exec.Supervisors
  alias Jido.Exec.Telemetry

  require Logger

  @type action :: module()
  @type params :: map()
  @type context :: map()
  @type run_opts :: [timeout: non_neg_integer()]
  @type exec_result ::
          {:ok, map(), [Jido.Agent.Directive.t()]}
          | {:error, Exception.t()}

  @doc """
  Checks if compensation is enabled for the given action.

  Compensation is enabled if:
  1. The action's metadata includes compensation configuration with `enabled: true`
  2. The action exports the `on_error/4` function

  ## Parameters

  - `action`: The action module to check

  ## Returns

  - `true` if compensation is enabled and available
  - `false` otherwise
  """
  @spec enabled?(action()) :: boolean()
  def enabled?(action) do
    metadata = action.__action_metadata__()
    compensation_opts = metadata[:compensation] || []

    enabled =
      case compensation_opts do
        opts when is_list(opts) -> Keyword.get(opts, :enabled, false)
        %{enabled: enabled} -> enabled
        _ -> false
      end

    enabled && function_exported?(action, :on_error, 4)
  end

  @doc """
  Handles action errors by executing compensation if enabled.

  This is the main entry point for error handling with compensation.
  If compensation is enabled, it will execute the action's `on_error/4` callback
  within a timeout. If compensation is disabled, it returns the original error.

  ## Parameters

  - `action`: The action module that failed
  - `params`: The parameters that were passed to the action
  - `context`: The context that was passed to the action
  - `error_or_tuple`: The error from the failed action, either an Exception or {Exception, directive}
  - `opts`: Execution options including timeout

  ## Returns

  - `{:error, compensated_error}` if compensation was attempted
  - `{:error, original_error}` if compensation is disabled
  """
  @spec handle_error(action(), params(), context(), Exception.t(), run_opts()) :: exec_result
  def handle_error(action, params, context, error, opts) do
    Logger.debug("Handle Action Error in handle_error: #{inspect(opts)}")

    if enabled?(action) do
      execute_compensation(action, params, context, error, opts)
    else
      {:error, error}
    end
  end

  # Private functions are exposed to the test suite
  private do
    @spec execute_compensation(action(), params(), context(), Exception.t(), run_opts()) ::
            exec_result
    defp execute_compensation(action, params, context, error, opts) do
      metadata = action.__action_metadata__()
      compensation_opts = metadata[:compensation] || []
      timeout = get_compensation_timeout(opts, compensation_opts)

      current_gl = Process.group_leader()
      task_sup = Supervisors.task_supervisor(opts)
      parent = self()
      ref = make_ref()

      compensation_run_opts =
        opts
        |> Keyword.take([:timeout, :backoff, :telemetry, :jido])
        |> Keyword.put(:compensation_timeout, timeout)

      {:ok, pid} =
        Task.Supervisor.start_child(task_sup, fn ->
          Process.group_leader(self(), current_gl)
          result = action.on_error(params, error, context, compensation_run_opts)
          send(parent, {:compensation_result, ref, result})
        end)

      monitor_ref = Process.monitor(pid)

      result =
        receive do
          {:compensation_result, ^ref, result} ->
            {:ok, result}

          {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
            case reason do
              :normal ->
                receive do
                  {:compensation_result, ^ref, result} -> {:ok, result}
                after
                  0 -> {:exit, reason}
                end

              _ ->
                {:exit, reason}
            end
        after
          timeout ->
            _ = Task.Supervisor.terminate_child(task_sup, pid)
            wait_for_down(monitor_ref, pid, 100)
            :timeout
        end

      cleanup_after_compensation(monitor_ref, ref)
      handle_task_result(result, error, timeout)
    end

    defp wait_for_down(monitor_ref, pid, wait_ms) do
      receive do
        {:DOWN, ^monitor_ref, :process, ^pid, _} -> :ok
      after
        wait_ms -> :ok
      end
    end

    defp cleanup_after_compensation(monitor_ref, ref) do
      Process.demonitor(monitor_ref, [:flush])
      flush_compensation_results(ref)
    end

    defp flush_compensation_results(ref) do
      receive do
        {:compensation_result, ^ref, _} ->
          flush_compensation_results(ref)
      after
        0 -> :ok
      end
    end

    @spec get_compensation_timeout(run_opts(), keyword() | map()) :: non_neg_integer()
    defp get_compensation_timeout(opts, compensation_opts) do
      Keyword.get(opts, :timeout) || extract_timeout_from_compensation_opts(compensation_opts)
    end

    @spec extract_timeout_from_compensation_opts(keyword() | map() | any()) :: non_neg_integer()
    defp extract_timeout_from_compensation_opts(opts) when is_list(opts),
      do: Keyword.get(opts, :timeout, 5_000)

    defp extract_timeout_from_compensation_opts(%{timeout: timeout}), do: timeout
    defp extract_timeout_from_compensation_opts(_), do: 5_000

    @spec handle_task_result(
            {:ok, any()} | {:exit, any()} | :timeout,
            Exception.t(),
            non_neg_integer()
          ) :: exec_result
    defp handle_task_result({:ok, result}, error, _timeout) do
      {:error, build_compensation_error(result, error)}
    end

    defp handle_task_result(:timeout, error, timeout) do
      {:error, build_timeout_error(error, timeout)}
    end

    defp handle_task_result({:exit, reason}, error, _timeout) do
      {:error, build_exit_error(error, reason)}
    end

    @spec build_timeout_error(Exception.t(), non_neg_integer()) :: Exception.t()
    defp build_timeout_error(error, timeout) do
      Error.execution_error(
        "Compensation timed out after #{timeout}ms for: #{inspect(error)}",
        %{
          compensated: false,
          compensation_error: "Compensation timed out after #{timeout}ms",
          original_error: error
        }
      )
    end

    @spec build_exit_error(Exception.t(), any()) :: Exception.t()
    defp build_exit_error(error, reason) do
      error_message = Telemetry.extract_safe_error_message(error)

      Error.execution_error(
        "Compensation crashed for: #{error_message}",
        %{
          compensated: false,
          compensation_error: "Compensation exited: #{inspect(reason)}",
          exit_reason: reason,
          original_error: error
        }
      )
    end

    @spec build_compensation_error(any(), Exception.t()) :: Exception.t()
    defp build_compensation_error({:ok, comp_result}, original_error) do
      # Extract fields that should be at the top level of the details
      {top_level_fields, remaining_fields} =
        Map.split(comp_result, [:test_value, :compensation_context])

      # Create the details map with the compensation result
      details =
        Map.merge(
          %{
            compensated: true,
            compensation_result: remaining_fields
          },
          top_level_fields
        )

      # Extract message from error struct properly using safe helper
      error_message = Telemetry.extract_safe_error_message(original_error)

      Error.execution_error(
        "Compensation completed for: #{error_message}",
        Map.put(details, :original_error, original_error)
      )
    end

    defp build_compensation_error({:error, comp_error}, original_error) do
      # Extract message from error struct properly using safe helper
      error_message = Telemetry.extract_safe_error_message(original_error)

      Error.execution_error(
        "Compensation failed for: #{error_message}",
        %{
          compensated: false,
          compensation_error: comp_error,
          original_error: original_error
        }
      )
    end

    defp build_compensation_error(_invalid_result, original_error) do
      Error.execution_error(
        "Invalid compensation result for: #{inspect(original_error)}",
        %{
          compensated: false,
          compensation_error: "Invalid compensation result",
          original_error: original_error
        }
      )
    end
  end
end
