defmodule Jido.Dsl.Agent.LegacyTranslator do
  @moduledoc false
  # Converts a legacy keyword list (`use Jido.Agent, name: …, plugins: …,
  # signal_routes: …, …`) into AST that drives the new sectioned DSL:
  # `use Jido.Agent, extensions: […]; agent do … end; signal_routes do … end;
  # schedules do … end`.
  #
  # Used by `Jido.Pod.__using__/1` so the pod wrapper keeps composing the
  # agent macro from a programmatically-built keyword list while task 0034 ports
  # the agent surface to the sectioned DSL. Should not be used for new code —
  # write the sectioned form directly.

  @agent_keys [:name, :description, :category, :tags, :vsn, :path, :schema]
  @use_keys [:default_slices, :jido]

  @doc """
  Returns AST that, when spliced into a module body, configures the agent
  surface from `opts`.
  """
  def quoted_agent_use(opts) do
    {agent_block_opts, opts} = Keyword.split(opts, @agent_keys)
    {use_keyword_opts, opts} = Keyword.split(opts, @use_keys)
    {plugins, opts} = Keyword.pop(opts, :plugins, [])
    {slices, opts} = Keyword.pop(opts, :slices, [])
    {middleware, opts} = Keyword.pop(opts, :middleware, [])
    {routes, opts} = Keyword.pop(opts, :signal_routes, [])
    {schedules, _opts} = Keyword.pop(opts, :schedules, [])

    extensions =
      List.wrap(middleware) ++ List.wrap(plugins) ++ List.wrap(slices)

    use_opts = [{:extensions, extensions} | use_keyword_opts]

    [
      quote do
        use Jido.Agent, unquote(Macro.escape(use_opts))
      end,
      quoted_agent_block(agent_block_opts),
      quoted_signal_routes_block(routes),
      quoted_schedules_block(schedules)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp quoted_agent_block([]), do: nil

  defp quoted_agent_block(agent_opts) do
    body =
      Enum.flat_map(agent_opts, fn {key, value} ->
        [
          quote do
            unquote({key, [], [Macro.escape(value)]})
          end
        ]
      end)

    quote do
      agent do
        (unquote_splicing(body))
      end
    end
  end

  defp quoted_signal_routes_block([]), do: nil

  defp quoted_signal_routes_block(routes) do
    body = Enum.map(routes, &quoted_route/1)

    quote do
      signal_routes do
        (unquote_splicing(body))
      end
    end
  end

  defp quoted_route({type, action}) do
    {:route, [], [type, action]}
  end

  defp quoted_route({type, action, priority}) when is_integer(priority) do
    {:route, [], [type, action, [priority: priority]]}
  end

  defp quoted_route({type, match, action}) when is_function(match, 1) do
    quote do
      route unquote(type), unquote(action), match: unquote(match)
    end
  end

  defp quoted_route({type, match, action, priority})
       when is_function(match, 1) and is_integer(priority) do
    quote do
      route unquote(type), unquote(action),
        match: unquote(match),
        priority: unquote(priority)
    end
  end

  defp quoted_schedules_block([]), do: nil

  defp quoted_schedules_block(schedules) do
    body = Enum.map(schedules, &quoted_schedule/1)

    quote do
      schedules do
        (unquote_splicing(body))
      end
    end
  end

  defp quoted_schedule({cron, signal_type}) when is_binary(cron) and is_binary(signal_type) do
    {:schedule, [], [cron, signal_type]}
  end

  defp quoted_schedule({cron, signal_type, sched_opts})
       when is_binary(cron) and is_binary(signal_type) and is_list(sched_opts) do
    {:schedule, [], [cron, signal_type, sched_opts]}
  end
end
