defmodule Jido.Dsl.Agent.Verifiers.UniquePaths do
  @moduledoc """
  Replaces the legacy `Duplicate slice paths` raise inside
  `__quoted_compile_instances__/0`. Asserts that the agent's own slice
  path and every plugin / slice path are unique.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    own_path = Verifier.get_option(dsl_state, [:agent], :path)
    plugin_paths = Verifier.get_persisted(dsl_state, :plugin_paths) || []
    slice_paths = Verifier.get_persisted(dsl_state, :slice_paths) || []

    all_paths =
      [own_path | plugin_paths ++ slice_paths]
      |> Enum.reject(&is_nil/1)

    duplicates = all_paths -- Enum.uniq(all_paths)

    if duplicates == [] do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         message: "Duplicate slice paths: #{inspect(Enum.uniq(duplicates))}",
         path: [:agent]
       )}
    end
  end
end
