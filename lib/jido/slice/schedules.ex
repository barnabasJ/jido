defmodule Jido.Slice.Schedules do
  @moduledoc """
  Utilities for expanding and managing slice schedules.

  This module handles:
  - Expanding schedule declarations from slice manifests
  - Generating unique job IDs namespaced to slice mounts
  - Generating signal types for schedule triggers

  ## Schedule Formats

  Schedules can be specified in several formats:

  - `{"*/5 * * * *", ActionModule}` - Simple schedule with default timezone
  - `{"*/5 * * * *", ActionModule, tz: "America/New_York"}` - With timezone
  - `{"*/5 * * * *", ActionModule, signal: "custom.signal"}` - Custom signal type

  ## Signal Type Generation

  By default, schedule signal types are auto-generated as:
  `"{path}.__schedule__.{action_name}"`

  ## Job ID Namespacing

  Job IDs are namespaced as tuples to ensure uniqueness across slice mounts:
  `{:slice_schedule, mount_path, ActionModule}`
  """

  alias Jido.Dsl.Slice.Info, as: SliceInfo
  alias Jido.Slice.Instance

  @schedule_route_priority -20

  @typedoc """
  Represents an expanded schedule specification.
  """
  @type schedule_spec :: %{
          cron_expression: String.t(),
          action: module(),
          job_id: {:slice_schedule, atom(), module()},
          signal_type: String.t(),
          timezone: String.t()
        }

  @doc """
  Expands schedules from a slice instance.

  Takes a slice instance and returns expanded schedule specifications
  with unique job IDs and auto-generated signal types.
  """
  @spec expand_schedules(Instance.t()) :: [schedule_spec()]
  def expand_schedules(%Instance{} = instance) do
    schedules = SliceInfo.schedules(instance.module)
    mount_path = instance.path
    prefix = Atom.to_string(mount_path)

    Enum.map(schedules, fn schedule ->
      expand_schedule(schedule, mount_path, prefix)
    end)
  end

  @doc """
  Generates routes for schedule signal types.

  Schedule signal types need routes so they can be dispatched through
  the normal signal routing pipeline. These routes have low priority
  to avoid conflicting with explicit routes.

  Returns a list of route tuples suitable for the agent's route table.
  """
  @spec schedule_routes(Instance.t()) :: [{String.t(), module(), keyword()}]
  def schedule_routes(%Instance{} = instance) do
    instance
    |> expand_schedules()
    |> Enum.map(fn spec ->
      {spec.signal_type, spec.action, [priority: @schedule_route_priority]}
    end)
  end

  @doc """
  Returns the default priority for schedule-generated routes.
  """
  @spec schedule_route_priority() :: integer()
  def schedule_route_priority, do: @schedule_route_priority

  defp expand_schedule({cron_expr, action}, mount_path, prefix) do
    expand_schedule({cron_expr, action, []}, mount_path, prefix)
  end

  defp expand_schedule({cron_expr, action, opts}, mount_path, prefix)
       when is_list(opts) do
    timezone = Keyword.get(opts, :tz, "Etc/UTC")
    custom_signal = Keyword.get(opts, :signal)

    signal_type =
      if custom_signal do
        "#{prefix}.#{custom_signal}"
      else
        generate_signal_type(prefix, action)
      end

    job_id = {:slice_schedule, mount_path, action}

    %{
      cron_expression: cron_expr,
      action: action,
      job_id: job_id,
      signal_type: signal_type,
      timezone: timezone
    }
  end

  defp generate_signal_type(prefix, action) do
    action_name =
      action
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    "#{prefix}.__schedule__.#{action_name}"
  end
end
