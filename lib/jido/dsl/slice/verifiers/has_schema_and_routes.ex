defmodule Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutes do
  @moduledoc """
  Enforces "a slice = shape + signal-routed actions". Every `use Jido.Slice`
  / `use Jido.Plugin` module must declare a `schema:` option in its
  `slice do … end` section and at least one entry in `signal_routes do …
  end`. A slice without a schema has no shape to bind to `agent.state`; a
  slice without routes is unreachable through the signal pipeline and can
  only be mutated by bypassing the action surface.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    schema = Verifier.get_option(dsl_state, [:slice], :schema)
    routes = Verifier.get_entities(dsl_state, [:signal_routes])

    cond do
      not schema_present?(schema) ->
        {:error,
         Spark.Error.DslError.exception(
           message:
             "Slice must declare a `schema:` in its `slice do … end` section. " <>
               "Slices bind a shape to `agent.state[path]`; a slice without a schema " <>
               "has nothing to bind. Provide a Zoi schema describing the slice's state.",
           path: [:slice, :schema]
         )}

      routes == [] ->
        {:error,
         Spark.Error.DslError.exception(
           message:
             "Slice must declare at least one route in its `signal_routes do … end` " <>
               "section. A slice without routes is unreachable through the signal " <>
               "pipeline; the only way to mutate its state would bypass middleware " <>
               "and the action surface. Add at least one `route \"…\", Action`.",
           path: [:signal_routes]
         )}

      true ->
        :ok
    end
  end

  defp schema_present?(nil), do: false
  defp schema_present?([]), do: false
  defp schema_present?(_), do: true
end
