defmodule Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutes do
  @moduledoc """
  Enforces that every `use Jido.Slice` module declares a `schema:`
  option in its `slice do … end` section. A slice without a schema has
  no shape to bind to `agent.state`.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    schema = Verifier.get_option(dsl_state, [:slice], :schema)

    if schema_present?(schema) do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         message:
           "Slice must declare a `schema:` in its `slice do … end` section. " <>
             "Slices bind a shape to `agent.state[path]`; a slice without a schema " <>
             "has nothing to bind. Provide a Zoi schema describing the slice's state.",
         path: [:slice, :schema]
       )}
    end
  end

  defp schema_present?(nil), do: false
  defp schema_present?([]), do: false
  defp schema_present?(_), do: true
end
