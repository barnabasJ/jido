defmodule Jido.Dsl.Agent.Verifiers.NoRouteConflicts do
  @moduledoc """
  Reads the conflict-detection result persisted by
  `Jido.Dsl.Agent.Transformers.ExpandRoutes` and raises a Spark DSL
  error listing route conflicts between the agent's own routes and any
  plugin / slice routes.

  Multi-instance mounts of the same slice (`slice :slack_support, SlackPlugin;
  slice :slack_sales, SlackPlugin`) are NOT flagged here — `detect_conflicts/1`
  collapses identical `(target, priority, on_conflict)` triples before the
  conflict scan, and `cmd/2` fans the action out across each owning mount at
  dispatch time. A real conflict is two different actions claiming the same
  signal type at the same priority.
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
