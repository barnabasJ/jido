defmodule Jido.Ash.Domain.Info do
  @moduledoc """
  Introspection helpers for Ash domains using `Jido.Ash.Domain`.
  """

  alias Spark.Dsl.Extension

  @section [:jido_agent]

  @doc "Returns the declared domain-backed agent name."
  @spec name(domain :: module()) :: String.t() | nil
  def name(domain), do: Extension.get_opt(domain, @section, :name)

  @doc "Returns the declared domain-backed agent description."
  @spec description(domain :: module()) :: String.t() | nil
  def description(domain), do: Extension.get_opt(domain, @section, :description)

  @doc "Returns the declared domain-backed agent category."
  @spec category(domain :: module()) :: String.t() | nil
  def category(domain), do: Extension.get_opt(domain, @section, :category)

  @doc "Returns declared tags for the domain-backed agent."
  @spec tags(domain :: module()) :: [String.t()]
  def tags(domain), do: Extension.get_opt(domain, @section, :tags) || []

  @doc "Returns the declared domain-backed agent version."
  @spec vsn(domain :: module()) :: String.t() | nil
  def vsn(domain), do: Extension.get_opt(domain, @section, :vsn)

  @doc "Returns normalized slice instances for the domain-backed composition."
  @spec slice_instances(domain :: module()) :: [Jido.Slice.Instance.t()]
  def slice_instances(domain),
    do: Extension.get_persisted(domain, :jido_agent_slice_instances, [])

  @doc "Returns mount paths owned by the domain-backed composition."
  @spec slice_paths(domain :: module()) :: [atom()]
  def slice_paths(domain), do: Extension.get_persisted(domain, :jido_agent_slice_paths, [])

  @doc "Returns generated action modules attached through mounted slices."
  @spec actions(domain :: module()) :: [module()]
  def actions(domain), do: Extension.get_persisted(domain, :jido_agent_actions, [])

  @doc "Returns expanded route tuples for the mounted slices."
  @spec routes(domain :: module()) :: [{String.t(), module(), integer()}]
  def routes(domain), do: Extension.get_persisted(domain, :jido_agent_routes, [])

  @doc "Returns the action module to mount-path table for the composition."
  @spec slice_paths_for_action(domain :: module()) :: %{module() => [atom()]}
  def slice_paths_for_action(domain) do
    Extension.get_persisted(domain, :jido_agent_slice_paths_for_action, %{})
  end

  @doc "Returns per-mount resolved configuration."
  @spec mount_config_map(domain :: module()) :: %{atom() => map()}
  def mount_config_map(domain),
    do: Extension.get_persisted(domain, :jido_agent_mount_config_map, %{})
end
