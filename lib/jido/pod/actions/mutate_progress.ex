defmodule Jido.Pod.Actions.MutateProgress do
  @moduledoc false

  alias Jido.Pod.Directive.StartNode
  alias Jido.Pod.Directive.StopNode
  alias Jido.Pod.Mutation.Plan
  alias Jido.Pod.Mutation.Report

  use Jido.Action,
    name: "pod_mutate_progress",
    path: :pod,
    schema: []

  def run(%Jido.Signal{type: type, data: data}, slice, _opts, _ctx) do
    name = Map.get(data, :tag)

    case slice[:mutation] do
      %{status: :running, awaiting: %{names: names} = awaiting, phase: phase} = mutation
      when not is_nil(names) ->
        if MapSet.member?(names, name) and signal_resolves_await?(type, awaiting, phase) do
          handle_awaited(slice, mutation, type, data, name, names)
        else
          {:ok, slice, []}
        end

      _ ->
        {:ok, slice, []}
    end
  end

  # During a stop wave we only progress on child.exit. During a start wave,
  # child.started is the happy path; child.exit for an awaited name means
  # the boot crashed before notify_parent_of_startup fired — startup
  # failure, surfaced as a wave failure.
  defp signal_resolves_await?("jido.agent.child.exit", %{kind: :exit}, _phase), do: true
  defp signal_resolves_await?("jido.agent.child.started", %{kind: :started}, _phase), do: true

  defp signal_resolves_await?("jido.agent.child.exit", %{kind: :started}, {:start_wave, _}),
    do: true

  defp signal_resolves_await?(_type, _awaiting, _phase), do: false

  defp handle_awaited(slice, mutation, type, data, name, names) do
    updated_report = update_report(mutation.report, mutation.phase, type, data)
    new_names = MapSet.delete(names, name)

    mutation =
      mutation
      |> Map.put(:report, updated_report)
      |> Map.put(:awaiting, %{mutation.awaiting | names: new_names})

    cond do
      MapSet.size(new_names) > 0 ->
        {:ok, %{slice | mutation: mutation}, []}

      startup_failures?(mutation) ->
        complete(slice, mutation, :failed)

      true ->
        advance(slice, mutation)
    end
  end

  defp update_report(%Report{} = report, {:stop_wave, _n}, "jido.agent.child.exit", %{tag: tag}) do
    %{report | stopped: append_unique(report.stopped, tag)}
  end

  defp update_report(
         %Report{} = report,
         {:start_wave, _n},
         "jido.agent.child.started",
         %{tag: tag} = data
       ) do
    pid = Map.get(data, :pid)
    nodes = Map.get(report, :nodes, %{})

    %{
      report
      | started: append_unique(report.started, tag),
        nodes: Map.put(nodes, tag, %{pid: pid, source: :started})
    }
  end

  defp update_report(
         %Report{} = report,
         {:start_wave, _n},
         "jido.agent.child.exit",
         %{tag: tag, reason: reason}
       ) do
    %{report | failures: Map.put(report.failures, tag, {:start_failed, reason})}
  end

  defp update_report(report, _phase, _type, _data), do: report

  defp startup_failures?(%{report: %Report{failures: failures}}), do: map_size(failures) > 0
  defp startup_failures?(_), do: false

  defp advance(slice, %{phase: phase, plan: %Plan{} = plan} = mutation) do
    case next_phase(phase, plan) do
      {next_phase_value, awaiting, directives} ->
        updated = %{mutation | phase: next_phase_value, awaiting: awaiting}
        {:ok, %{slice | mutation: updated}, directives}

      :done ->
        complete(slice, mutation, :completed)
    end
  end

  defp next_phase({:stop_wave, n}, %Plan{stop_waves: stops} = plan) do
    case Enum.at(stops, n + 1) do
      nil -> first_start_phase(plan)
      next_wave -> stop_wave_phase(n + 1, next_wave)
    end
  end

  defp next_phase({:start_wave, n}, %Plan{start_waves: starts} = plan) do
    case Enum.at(starts, n + 1) do
      nil -> :done
      next_wave -> start_wave_phase(n + 1, next_wave, plan)
    end
  end

  defp first_start_phase(%Plan{start_waves: []}), do: :done
  defp first_start_phase(%Plan{start_waves: [first | _]} = plan), do: start_wave_phase(0, first, plan)

  defp stop_wave_phase(index, names) do
    {{:stop_wave, index}, %{kind: :exit, names: MapSet.new(names)},
     Enum.map(names, &StopNode.new!/1)}
  end

  defp start_wave_phase(index, names, %Plan{start_state_overrides: overrides}) do
    {{:start_wave, index}, %{kind: :started, names: MapSet.new(names)},
     Enum.map(names, &start_directive(&1, overrides))}
  end

  defp start_directive(name, overrides) do
    case Map.get(overrides, name) do
      nil -> StartNode.new!(name)
      state when is_map(state) -> StartNode.new!(name, initial_state: state)
    end
  end

  defp complete(slice, mutation, status) do
    final_report = finalize_report(mutation.report, status)

    final_mutation = %{
      mutation
      | status: status,
        phase: :complete,
        awaiting: nil,
        report: final_report,
        error: if(status == :failed, do: final_report, else: nil)
    }

    {:ok, %{slice | mutation: final_mutation}, []}
  end

  defp finalize_report(%Report{} = report, status) do
    %{
      report
      | status: status,
        started: Enum.sort(report.started),
        stopped: Enum.sort(report.stopped)
    }
  end

  defp finalize_report(report, _status), do: report

  defp append_unique(items, item) do
    if item in items, do: items, else: items ++ [item]
  end
end
