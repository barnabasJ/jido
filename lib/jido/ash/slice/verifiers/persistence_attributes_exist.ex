defmodule Jido.Ash.Slice.Verifiers.PersistenceAttributesExist do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Jido.Ash.Slice.PersistenceEntry
  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  @spec verify(dsl_state :: map()) :: :ok | {:error, Spark.Error.DslError.t()}
  def verify(dsl_state) do
    entries =
      dsl_state
      |> Verifier.get_entities([:jido_slice])
      |> Enum.filter(&match?(%PersistenceEntry{}, &1))

    resource = Verifier.get_persisted(dsl_state, :module)

    case Enum.find(entries, &missing_attribute?(resource, &1.attribute)) do
      nil ->
        :ok

      entry ->
        {:error,
         Spark.Error.DslError.exception(
           message:
             "jido_slice persist #{inspect(entry.attribute)} references missing Ash attribute",
           path: [:jido_slice, :persist]
         )}
    end
  end

  defp missing_attribute?(resource, attribute) do
    is_nil(Ash.Resource.Info.attribute(resource, attribute))
  end
end
