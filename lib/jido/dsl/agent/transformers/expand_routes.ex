defmodule Jido.Dsl.Agent.Transformers.ExpandRoutes do
  @moduledoc """
  Expands plugin / slice routes (with prefixing for plugins, absolute
  paths for slices) and agent / plugin schedules into the runtime
  route_spec tuple shape and persists each expansion under its dsl_state
  key:

    * `:expanded_signal_routes` — host-declared `signal_routes do … end`
      flattened to route_spec tuples.
    * `:expanded_plugin_routes` and `:expanded_slice_routes` — per-instance
      route expansions.
    * `:expanded_plugin_schedules` and `:expanded_agent_schedules` — cron
      schedule specs.
    * `:validated_plugin_routes` — combined and conflict-checked.

  Conflict detection raises in `Jido.Dsl.Agent.Verifiers.NoRouteConflicts`;
  this transformer only does the expansion.
  """

  use Spark.Dsl.Transformer

  alias Jido.Dsl.Agent.Route
  alias Jido.Dsl.Agent.Schedule
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(Jido.Dsl.Agent.Transformers.WalkExtensions), do: true
  def after?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    expanded_signal_routes = build_signal_routes(dsl_state)
    plugin_instances = Transformer.get_persisted(dsl_state, :plugin_instances, [])
    slice_instances = Transformer.get_persisted(dsl_state, :slice_instances, [])

    expanded_plugin_routes =
      Enum.flat_map(plugin_instances, &Jido.Plugin.Routes.expand_routes/1)

    expanded_slice_routes =
      Enum.flat_map(slice_instances, &Jido.Slice.Instance.expand_routes/1)

    expanded_plugin_schedules =
      Enum.flat_map(plugin_instances, &Jido.Plugin.Schedules.expand_schedules/1)

    schedule_routes =
      Enum.flat_map(plugin_instances, &Jido.Plugin.Schedules.schedule_routes/1)

    agent_name = Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :name)

    expanded_agent_schedules =
      dsl_state
      |> agent_schedules_input()
      |> Jido.Agent.Schedules.expand_schedules(agent_name)

    agent_schedule_routes =
      Jido.Agent.Schedules.schedule_routes(expanded_agent_schedules)

    all_plugin_routes =
      expanded_plugin_routes ++
        expanded_slice_routes ++
        schedule_routes ++ agent_schedule_routes

    plugin_routes_result = Jido.Plugin.Routes.detect_conflicts(all_plugin_routes)

    validated_plugin_routes =
      case plugin_routes_result do
        {:ok, routes} -> routes
        {:error, _} -> []
      end

    plugin_config_map =
      Enum.reduce(plugin_instances, %{}, fn instance, acc ->
        Map.put(acc, instance.path, instance.config)
      end)

    dsl_state =
      dsl_state
      |> Transformer.persist(:expanded_signal_routes, expanded_signal_routes)
      |> Transformer.persist(:expanded_plugin_routes, expanded_plugin_routes)
      |> Transformer.persist(:expanded_slice_routes, expanded_slice_routes)
      |> Transformer.persist(:expanded_plugin_schedules, expanded_plugin_schedules)
      |> Transformer.persist(:expanded_agent_schedules, expanded_agent_schedules)
      |> Transformer.persist(:all_plugin_routes, all_plugin_routes)
      |> Transformer.persist(:plugin_routes_result, plugin_routes_result)
      |> Transformer.persist(:validated_plugin_routes, validated_plugin_routes)
      |> Transformer.persist(:plugin_config_map, plugin_config_map)

    {:ok, dsl_state}
  end

  defp build_signal_routes(dsl_state) do
    [:signal_routes]
    |> get_entities(dsl_state)
    |> Enum.map(&route_to_route_spec/1)
  end

  defp route_to_route_spec(%Route{type: type, action: action, priority: priority, match: nil}) do
    if priority == 0,
      do: {type, action},
      else: {type, action, priority}
  end

  defp route_to_route_spec(%Route{type: type, action: action, priority: priority, match: match})
       when is_function(match, 1) do
    if priority == 0,
      do: {type, match, action},
      else: {type, match, action, priority}
  end

  defp agent_schedules_input(dsl_state) do
    [:schedules]
    |> get_entities(dsl_state)
    |> Enum.map(fn %Schedule{} = s ->
      opts =
        []
        |> append_if(s.timezone, fn opts -> [{:timezone, s.timezone} | opts] end)
        |> append_if(s.job_id, fn opts -> [{:job_id, s.job_id} | opts] end)

      case opts do
        [] -> {s.cron, s.signal_type}
        opts -> {s.cron, s.signal_type, opts}
      end
    end)
  end

  defp append_if(opts, nil, _fun), do: opts
  defp append_if(opts, _, fun), do: fun.(opts)

  defp get_entities(path, dsl_state), do: Transformer.get_entities(dsl_state, path)
end
