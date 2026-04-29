defmodule Jido.Dsl.Agent.Verifiers.NoSectionNameCollisions do
  @moduledoc """
  Rejects two extensions contributing the same section name (per ADR
  0023 §3). For task 0034 the registered extensions don't yet
  contribute their own typed sections — they will once task 0035 lands.
  This verifier exists so the host's section list is checked for
  duplicates as soon as any extension does start adding sections.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    extensions = Verifier.get_persisted(dsl_state, :extensions) || []

    contributions =
      Enum.flat_map(extensions, fn ext ->
        sections =
          if function_exported?(ext, :sections, 0) do
            ext.sections()
          else
            []
          end

        Enum.map(sections, fn section -> {section.name, ext} end)
      end)

    duplicates =
      contributions
      |> Enum.group_by(fn {name, _ext} -> name end, fn {_name, ext} -> ext end)
      |> Enum.filter(fn {_name, exts} -> length(Enum.uniq(exts)) > 1 end)

    case duplicates do
      [] ->
        :ok

      list ->
        message =
          Enum.map_join(list, "; ", fn {name, exts} ->
            mods = exts |> Enum.uniq() |> Enum.map_join(", ", &inspect/1)
            "section #{inspect(name)} is contributed by multiple extensions: #{mods}"
          end)

        {:error,
         Spark.Error.DslError.exception(
           message: "Section name collisions: #{message}",
           path: []
         )}
    end
  end
end
