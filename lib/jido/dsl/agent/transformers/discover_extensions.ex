defmodule Jido.Dsl.Agent.Transformers.DiscoverExtensions do
  @moduledoc """
  Validates that user-listed extensions don't contribute colliding
  section names. Persists `:jido_contributed_sections` mapping
  `module -> section_name` for `WalkExtensions` to read.

  Runs before `WalkExtensions` so the latter can look up each
  registered extension's contributed section name and read the
  matching block out of `dsl_state`.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def before?(Jido.Dsl.Agent.Transformers.WalkExtensions), do: true
  def before?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    extensions = Transformer.get_persisted(dsl_state, :jido_user_extensions, [])

    contributions =
      extensions
      |> Enum.flat_map(&extract_contribution/1)

    case detect_collisions(contributions) do
      [] ->
        contributed_sections =
          Map.new(contributions, fn {section, mod} -> {mod, section} end)

        {:ok, Transformer.persist(dsl_state, :jido_contributed_sections, contributed_sections)}

      collisions ->
        {:error, collision_error(collisions)}
    end
  end

  defp extract_contribution(entry) do
    module = extract_module(entry)

    cond do
      module == nil ->
        []

      Code.ensure_loaded?(module) and function_exported?(module, :__jido_host_section__, 0) ->
        [{module.__jido_host_section__(), module}]

      true ->
        []
    end
  end

  defp extract_module(module) when is_atom(module), do: module
  defp extract_module({module, _opts}) when is_atom(module), do: module
  defp extract_module(_other), do: nil

  defp detect_collisions(contributions) do
    contributions
    |> Enum.group_by(fn {section, _mod} -> section end, fn {_, mod} -> mod end)
    |> Enum.filter(fn {_section, mods} -> length(Enum.uniq(mods)) > 1 end)
  end

  defp collision_error(collisions) do
    msg =
      Enum.map_join(collisions, "; ", fn {section, mods} ->
        names = mods |> Enum.uniq() |> Enum.map_join(", ", &inspect/1)
        "section #{inspect(section)} contributed by multiple extensions: #{names}"
      end)

    Spark.Error.DslError.exception(message: "Section name collisions: " <> msg, path: [])
  end
end
