defmodule Jido.Dsl.Agent.Transformers.MergeSchemas do
  @moduledoc """
  Merges the agent's base schema (declared in `agent do schema …`) with
  the schemas of every bare-slice instance attached to the agent.
  Persists the merged schema as `:merged_schema`.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(Jido.Dsl.Agent.Transformers.WalkExtensions), do: true
  def after?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    base_schema =
      Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :schema, [])

    slice_pseudo_specs = Transformer.get_persisted(dsl_state, :slice_pseudo_specs, [])

    merged_schema =
      Jido.Agent.Schema.merge_with_plugins(base_schema, slice_pseudo_specs)

    {:ok, Transformer.persist(dsl_state, :merged_schema, merged_schema)}
  end
end
