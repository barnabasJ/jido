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

  @doc "Returns the deduplicated list of bare-slice modules attached to this agent."
  @spec slices(module()) :: [module()]
  def slices(module) do
    module
    |> slice_instances()
    |> Enum.map(& &1.module)
    |> Enum.uniq()
  end

  @doc "Returns the list of slice instances attached to this agent."
  @spec slice_instances(module()) :: [Jido.Slice.Instance.t()]
  def slice_instances(module),
    do: Extension.get_persisted(module, :slice_instances, [])

  @doc "Returns the slice paths owned by attached slices."
  @spec slice_paths(module()) :: [atom()]
  def slice_paths(module),
    do: Extension.get_persisted(module, :slice_paths, [])

  @doc "Returns the deduplicated list of action modules from all attached slices."
  @spec actions(module()) :: [module()]
  def actions(module), do: Extension.get_persisted(module, :plugin_actions, [])

  @doc "Returns the union of all capabilities from all mounted slices."
  @spec capabilities(module()) :: [atom()]
  def capabilities(module) do
    module
    |> slice_instances()
    |> Enum.flat_map(fn instance ->
      Jido.Dsl.Slice.Info.capabilities(instance.module)
    end)
    |> Enum.uniq()
  end

  @doc "Returns the expanded and validated routes for this agent."
  @spec routes(module()) :: [{String.t(), module(), integer()}]
  def routes(module),
    do: Extension.get_persisted(module, :validated_routes, [])

  @doc "Returns all expanded route signal types."
  @spec signal_types(module()) :: [String.t()]
  def signal_types(module) do
    module
    |> routes()
    |> Enum.map(fn {signal_type, _action, _priority} -> signal_type end)
  end

  @doc "Returns the expanded slice and agent schedules."
  @spec schedules(module()) :: [
          Jido.Slice.Schedules.schedule_spec()
          | Jido.Agent.Schedules.schedule_spec()
        ]
  def schedules(module) do
    Extension.get_persisted(module, :expanded_slice_schedules, []) ++
      Extension.get_persisted(module, :expanded_agent_schedules, [])
  end

  @doc "Returns the agent's expanded signal routes."
  @spec signal_routes(module()) :: list()
  def signal_routes(module),
    do: Extension.get_persisted(module, :expanded_signal_routes, [])

  @doc """
  Returns the compile-time `action_module => [mount_path, …]` map used by
  `cmd/2` to fan an action out across every mount that owns it.

  Multi-instance mounts of the same slice produce multi-element lists;
  single-mount actions are one-element lists; agent-level `signal_routes`
  declarations contribute the agent's own path. Actions not owned by any
  declared route are absent from the map (and resolved at runtime via the
  action's own `path :foo` escape valve or the agent's path).
  """
  @spec slice_paths_for_action(module()) :: %{module() => [atom()]}
  def slice_paths_for_action(module),
    do: Extension.get_persisted(module, :slice_paths_for_action, %{})

  @doc """
  Returns the compile-time `mount_path => config` map exposed to actions as
  `ctx.slice_config` during fan-out. Includes both plugin and slice mounts.
  """
  @spec mount_config_map(module()) :: %{atom() => map()}
  def mount_config_map(module),
    do: Extension.get_persisted(module, :mount_config_map, %{})

  @doc """
  Returns the resolved configuration for a specific slice attached to
  the agent, or `nil` if the slice isn't mounted.
  """
  @spec slice_config(module(), module()) :: map() | nil
  def slice_config(agent_module, slice_mod) when is_atom(slice_mod) do
    case Enum.find(slice_instances(agent_module), &(&1.module == slice_mod)) do
      nil -> nil
      instance -> instance.config
    end
  end

  @doc """
  Returns the slice of `agent.state` owned by a specific slice
  attached to the agent's module, or `nil` if the slice isn't mounted.
  """
  @spec slice_state(module(), Jido.Agent.t(), module()) :: map() | nil
  def slice_state(agent_module, agent, slice_mod) when is_atom(slice_mod) do
    case Enum.find(slice_instances(agent_module), &(&1.module == slice_mod)) do
      nil -> nil
      instance -> Map.get(agent.state, instance.path)
    end
  end
end
