defmodule Jido.Dsl.Agent.Transformers.ValidateRequirements do
  @moduledoc """
  Validates plugin requirements at compile time. Walks every mounted
  plugin/slice and checks that each `requires :kind, :name` entry is
  satisfied by the host configuration; raises a Spark DSL error
  otherwise.
  """

  use Spark.Dsl.Transformer

  alias Jido.Plugin.Requirements
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(Jido.Dsl.Agent.Transformers.ExpandRoutes), do: true
  def after?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    plugin_instances = Transformer.get_persisted(dsl_state, :plugin_instances, [])
    mount_config_map = Transformer.get_persisted(dsl_state, :mount_config_map, %{})

    case Requirements.validate_all_requirements(plugin_instances, mount_config_map) do
      {:ok, :valid} ->
        {:ok, dsl_state}

      {:error, missing_by_plugin} ->
        message = Requirements.format_error(missing_by_plugin)

        {:error,
         Spark.Error.DslError.exception(
           message: message,
           path: [:agent]
         )}
    end
  end
end
