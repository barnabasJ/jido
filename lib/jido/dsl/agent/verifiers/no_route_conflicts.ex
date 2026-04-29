defmodule Jido.Dsl.Agent.Verifiers.NoRouteConflicts do
  @moduledoc """
  Replaces the legacy `Jido.Plugin.Routes.detect_conflicts/1` raise
  inside `__quoted_compile_aggregates__/0`. Reads the conflict-detection
  result persisted by `Jido.Dsl.Agent.Transformers.ExpandRoutes` and
  raises a Spark DSL error listing conflicts.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    case Verifier.get_persisted(dsl_state, :plugin_routes_result) do
      {:ok, _} ->
        :ok

      {:error, conflicts} ->
        conflict_list = Enum.join(conflicts, "\n  - ")

        {:error,
         Spark.Error.DslError.exception(
           message: "Route conflicts detected:\n  - #{conflict_list}",
           path: [:signal_routes]
         )}

      nil ->
        :ok
    end
  end
end
