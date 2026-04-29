defmodule Jido.Dsl.Agent.Verifiers.NoSingletonAlias do
  @moduledoc """
  Replaces the legacy singleton-alias raise from
  `__quoted_compile_instances__/0`. Rejects:

    * Any plugin / slice instance whose module is `singleton?/0` and is
      registered with an `as:` override.
    * Duplicate registrations of the same singleton plugin module.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    plugin_instances = Verifier.get_persisted(dsl_state, :plugin_instances) || []
    slice_instances = Verifier.get_persisted(dsl_state, :slice_instances) || []

    instances = plugin_instances ++ slice_instances

    with :ok <- check_no_alias(instances) do
      check_no_duplicates(instances)
    end
  end

  defp check_no_alias(instances) do
    aliased =
      Enum.filter(instances, fn inst ->
        function_exported?(inst.module, :singleton?, 0) and
          inst.module.singleton?() and inst.as != nil
      end)

    if aliased == [] do
      :ok
    else
      modules = Enum.map_join(aliased, ", ", &inspect(&1.module))

      {:error,
       Spark.Error.DslError.exception(
         message: "Cannot alias singleton plugins: #{modules}",
         path: [:agent]
       )}
    end
  end

  defp check_no_duplicates(instances) do
    singleton_modules =
      instances
      |> Enum.filter(fn inst ->
        function_exported?(inst.module, :singleton?, 0) and inst.module.singleton?()
      end)
      |> Enum.map(& &1.module)

    duplicates = singleton_modules -- Enum.uniq(singleton_modules)

    if duplicates == [] do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         message: "Duplicate singleton plugins: #{inspect(Enum.uniq(duplicates))}",
         path: [:agent]
       )}
    end
  end
end
