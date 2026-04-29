defmodule Jido.Dsl.Agent.Transformers.ValidateRequirements do
  @moduledoc """
  Validates plugin requirements at compile time. Replaces the legacy
  `Jido.Plugin.Requirements.validate_all_requirements/2` raise inside
  `__quoted_compile_aggregates__/0`.
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
    plugin_config_map = Transformer.get_persisted(dsl_state, :plugin_config_map, %{})

    case Requirements.validate_all_requirements(plugin_instances, plugin_config_map) do
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
