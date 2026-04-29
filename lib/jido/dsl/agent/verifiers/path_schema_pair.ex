defmodule Jido.Dsl.Agent.Verifiers.PathSchemaPair do
  @moduledoc """
  Enforces the "both or neither" contract for the agent's `path:` and
  `schema:` options. A pure composition agent (one whose state is
  entirely owned by mounted slices) omits both. An agent with its own
  user-domain slice declares both. Setting only one is a configuration
  error: a `schema` with no `path` has nothing to bind to, and a `path`
  with no `schema` is a placeholder that contributes nothing useful.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    path = Verifier.get_option(dsl_state, [:agent], :path)
    schema = Verifier.get_option(dsl_state, [:agent], :schema)

    case {path, schema_present?(schema)} do
      {nil, false} ->
        :ok

      {path, true} when is_atom(path) and not is_nil(path) ->
        :ok

      {nil, true} ->
        {:error,
         dsl_error(
           "`schema:` is set in `agent do … end` but `path:` is not. " <>
             "Set both (the schema's slice key) or neither (a pure composition agent)."
         )}

      {path, false} when is_atom(path) and not is_nil(path) ->
        {:error,
         dsl_error(
           "`path: #{inspect(path)}` is set in `agent do … end` but `schema:` is not. " <>
             "Set both (the schema bound to this slice key) or neither (a pure composition agent)."
         )}
    end
  end

  defp schema_present?(nil), do: false
  defp schema_present?([]), do: false
  defp schema_present?(_), do: true

  defp dsl_error(message) do
    Spark.Error.DslError.exception(message: message, path: [:agent])
  end
end
