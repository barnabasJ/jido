defmodule Jido.Slice.Extension do
  @moduledoc """
  Helper for slices that opt into being a host-agent extension by
  contributing one typed DSL block (`<host_section> do … end`) to host
  modules that list them in `extensions: [...]`.

  Each contributing slice declares its `@<name>_section` literal and
  `use Spark.Dsl.Extension, …` directly in its module body, mirroring
  `Jido.Pod`. A small per-slice transformer
  (`<Slice>.Transformers.RegisterContribution`) calls
  `Spark.Dsl.Transformer.persist/3` to register the slice in the host's
  `:jido_contributed_sections` map.

  This module survives only as `build_section/2`, a callable helper for
  slices that want to auto-derive their `%Spark.Dsl.Section{}` from
  `config_schema/0` instead of hand-writing a literal. Call it from
  positions where the slice has fully compiled (e.g. inside a transformer's
  `transform/1`); module-attribute-eval-time use is unsafe because the
  slice's DSL state isn't queryable mid-compile.
  """

  alias Jido.Dsl.Slice.Info, as: SliceInfo
  alias Jido.Slice.Extension.SchemaTranslate

  @doc """
  Builds the `%Spark.Dsl.Section{}` that the host agent surfaces for this
  slice. Translates `config_schema/0` (when present) into the section's
  schema entries.
  """
  @spec build_section(module(), atom()) :: Spark.Dsl.Section.t()
  def build_section(module, section_name) do
    %Spark.Dsl.Section{
      name: section_name,
      describe: section_describe(module),
      schema: build_schema(module)
    }
  end

  defp build_schema(module) do
    SchemaTranslate.translate(SliceInfo.config_schema(module))
  end

  defp section_describe(module) do
    SliceInfo.description(module) ||
      "Configuration block contributed by #{inspect(module)}."
  end
end
