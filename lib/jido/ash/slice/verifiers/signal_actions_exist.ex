defmodule Jido.Ash.Slice.Verifiers.SignalActionsExist do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Jido.Ash.Slice.SignalEntry
  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  @spec verify(dsl_state :: map()) :: :ok | {:error, Spark.Error.DslError.t()}
  def verify(dsl_state) do
    signals =
      dsl_state
      |> Verifier.get_entities([:jido_slice])
      |> Enum.filter(&match?(%SignalEntry{}, &1))

    resource = Verifier.get_persisted(dsl_state, :module)

    case Enum.find(signals, &missing_action?(resource, &1.action)) do
      nil ->
        :ok

      signal ->
        {:error,
         Spark.Error.DslError.exception(
           message:
             "jido_slice signal #{inspect(signal.type)} references missing Ash action " <>
               inspect(signal.action),
           path: [:jido_slice, :signal]
         )}
    end
  end

  defp missing_action?(resource, action) do
    is_nil(Ash.Resource.Info.action(resource, action))
  end
end
