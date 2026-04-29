defmodule Jido.Dsl.Agent.Info do
  @moduledoc """
  Introspection surface for `use Jido.Agent` modules.

  Reads the agent host's Spark `dsl_state` for the `:agent` /
  `:signal_routes` / `:schedules` sections, plus the cross-section values
  the agent's transformer pipeline persists (plugin instances, slice
  instances, plugin actions, expanded routes, merged schema, …).
  Replaces the per-agent hand-rolled accessor surface that the
  `GenerateAccessors` transformer used to emit on the agent module.
  """

  alias Spark.Dsl.Extension

  @section [:agent]

  @doc "Returns the agent's name."
  @spec name(module()) :: String.t() | nil
  def name(module), do: Extension.get_opt(module, @section, :name)

  @doc "Returns the agent's description."
  @spec description(module()) :: String.t() | nil
  def description(module), do: Extension.get_opt(module, @section, :description)

  @doc "Returns the agent's category."
  @spec category(module()) :: String.t() | nil
  def category(module), do: Extension.get_opt(module, @section, :category)

  @doc "Returns the agent's tags."
  @spec tags(module()) :: [String.t()]
  def tags(module), do: Extension.get_opt(module, @section, :tags) || []

  @doc "Returns the agent's version."
  @spec vsn(module()) :: String.t() | nil
  def vsn(module), do: Extension.get_opt(module, @section, :vsn)

  @doc """
  Returns the atom slice key where the agent's user-domain state lives,
  or `nil` for a pure composition agent that has no own slice.
  """
  @spec path(module()) :: atom() | nil
  def path(module), do: Extension.get_opt(module, @section, :path)

  @doc "Returns the merged schema (base + plugin schemas)."
  @spec schema(module()) :: term()
  def schema(module), do: Extension.get_persisted(module, :merged_schema, [])

  @doc "Returns the middleware modules attached to this agent."
  @spec middleware(module()) :: [module() | {module(), map()}]
  def middleware(module), do: Extension.get_persisted(module, :middleware_list, [])

  @doc "Returns the deduplicated list of plugin modules attached to this agent."
  @spec plugins(module()) :: [module()]
  def plugins(module) do
    module
    |> plugin_instances()
    |> Enum.map(& &1.module)
    |> Enum.uniq()
  end

  @doc "Returns the deduplicated list of bare-slice modules attached to this agent."
  @spec slices(module()) :: [module()]
  def slices(module) do
    module
    |> slice_instances()
    |> Enum.map(& &1.module)
    |> Enum.uniq()
  end

  @doc "Returns the list of plugin instances attached to this agent."
  @spec plugin_instances(module()) :: [Jido.Plugin.Instance.t()]
  def plugin_instances(module),
    do: Extension.get_persisted(module, :plugin_instances, [])

  @doc "Returns the list of slice instances attached to this agent."
  @spec slice_instances(module()) :: [Jido.Slice.Instance.t()]
  def slice_instances(module),
    do: Extension.get_persisted(module, :slice_instances, [])

  @doc "Returns the list of plugin specs attached to this agent."
  @spec plugin_specs(module()) :: [Jido.Plugin.Spec.t()]
  def plugin_specs(module),
    do: Extension.get_persisted(module, :plugin_specs, [])

  @doc "Returns the slice paths owned by attached plugins."
  @spec plugin_paths(module()) :: [atom()]
  def plugin_paths(module),
    do: Extension.get_persisted(module, :plugin_paths, [])

  @doc "Returns the slice paths owned by attached bare slices."
  @spec slice_paths(module()) :: [atom()]
  def slice_paths(module),
    do: Extension.get_persisted(module, :slice_paths, [])

  @doc "Returns the deduplicated list of action modules from all attached plugins and slices."
  @spec actions(module()) :: [module()]
  def actions(module), do: Extension.get_persisted(module, :plugin_actions, [])

  @doc "Returns the union of all capabilities from all mounted instances."
  @spec capabilities(module()) :: [atom()]
  def capabilities(module) do
    (plugin_instances(module) ++ slice_instances(module))
    |> Enum.flat_map(fn instance ->
      Jido.Dsl.Slice.Info.capabilities(instance.module)
    end)
    |> Enum.uniq()
  end

  @doc "Returns the expanded and validated plugin routes."
  @spec plugin_routes(module()) :: [{String.t(), module(), integer()}]
  def plugin_routes(module),
    do: Extension.get_persisted(module, :validated_plugin_routes, [])

  @doc "Returns all expanded route signal types from plugin routes."
  @spec signal_types(module()) :: [String.t()]
  def signal_types(module) do
    module
    |> plugin_routes()
    |> Enum.map(fn {signal_type, _action, _priority} -> signal_type end)
  end

  @doc "Returns the expanded plugin and agent schedules."
  @spec plugin_schedules(module()) :: [
          Jido.Plugin.Schedules.schedule_spec() | Jido.Agent.Schedules.schedule_spec()
        ]
  def plugin_schedules(module) do
    Extension.get_persisted(module, :expanded_plugin_schedules, []) ++
      Extension.get_persisted(module, :expanded_agent_schedules, [])
  end

  @doc "Returns the agent's expanded signal routes."
  @spec signal_routes(module()) :: list()
  def signal_routes(module),
    do: Extension.get_persisted(module, :expanded_signal_routes, [])

  @doc """
  Returns the resolved configuration for a specific plugin attached to
  the agent, or `nil` if the plugin isn't mounted.

  Accepts either the plugin module (matches the un-aliased instance) or
  `{Module, as_alias}` to disambiguate when multiple instances share the
  same plugin module.
  """
  @spec plugin_config(module(), module() | {module(), atom()}) :: map() | nil
  def plugin_config(agent_module, plugin_mod) when is_atom(plugin_mod) do
    instances = plugin_instances(agent_module)

    case Enum.find(instances, &(&1.module == plugin_mod and is_nil(&1.as))) do
      nil ->
        case Enum.find(instances, &(&1.module == plugin_mod)) do
          nil -> nil
          instance -> instance.config
        end

      instance ->
        instance.config
    end
  end

  def plugin_config(agent_module, {plugin_mod, as_alias})
      when is_atom(plugin_mod) and is_atom(as_alias) do
    case Enum.find(
           plugin_instances(agent_module),
           &(&1.module == plugin_mod and &1.as == as_alias)
         ) do
      nil -> nil
      instance -> instance.config
    end
  end

  @doc """
  Returns the slice of `agent.state` owned by a specific plugin
  attached to the agent's module, or `nil` if the plugin isn't mounted.
  """
  @spec plugin_state(module(), Jido.Agent.t(), module() | {module(), atom()}) :: map() | nil
  def plugin_state(agent_module, agent, plugin_mod) when is_atom(plugin_mod) do
    instances = plugin_instances(agent_module)

    case Enum.find(instances, &(&1.module == plugin_mod and is_nil(&1.as))) do
      nil ->
        case Enum.find(instances, &(&1.module == plugin_mod)) do
          nil -> nil
          instance -> Map.get(agent.state, instance.path)
        end

      instance ->
        Map.get(agent.state, instance.path)
    end
  end

  def plugin_state(agent_module, agent, {plugin_mod, as_alias})
      when is_atom(plugin_mod) and is_atom(as_alias) do
    case Enum.find(
           plugin_instances(agent_module),
           &(&1.module == plugin_mod and &1.as == as_alias)
         ) do
      nil -> nil
      instance -> Map.get(agent.state, instance.path)
    end
  end
end
