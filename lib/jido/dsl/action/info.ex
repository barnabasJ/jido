defmodule Jido.Dsl.Action.Info do
  @moduledoc """
  Introspection surface for `use Jido.Action` modules.

  Each accessor takes the action module and reads a field from the
  action's Spark `dsl_state`. Replaces the per-action hand-rolled
  accessor surface that the `GenerateAccessors` transformer used to
  emit on the action module.
  """

  alias Spark.Dsl.Extension

  @section [:action]

  @doc "Returns the name of the Action."
  @spec name(module()) :: String.t() | nil
  def name(module), do: Extension.get_opt(module, @section, :name)

  @doc "Returns the description of the Action."
  @spec description(module()) :: String.t() | nil
  def description(module), do: Extension.get_opt(module, @section, :description)

  @doc "Returns the category of the Action."
  @spec category(module()) :: String.t() | nil
  def category(module), do: Extension.get_opt(module, @section, :category)

  @doc "Returns the tags associated with the Action."
  @spec tags(module()) :: [String.t()]
  def tags(module), do: Extension.get_opt(module, @section, :tags) || []

  @doc "Returns the version of the Action."
  @spec vsn(module()) :: String.t() | nil
  def vsn(module), do: Extension.get_opt(module, @section, :vsn)

  @doc "Returns the input schema of the Action."
  @spec schema(module()) :: term()
  def schema(module), do: Extension.get_opt(module, @section, :schema, [])

  @doc "Returns the output schema of the Action."
  @spec output_schema(module()) :: term()
  def output_schema(module), do: Extension.get_opt(module, @section, :output_schema, [])

  @doc "Returns the compensation declaration."
  @spec compensation(module()) :: map()
  def compensation(module) do
    Extension.get_opt(
      module,
      @section,
      :compensation,
      %{enabled: false, max_retries: 1, timeout: 5000}
    )
  end

  @doc """
  Returns the Action metadata as a JSON-serializable map.
  """
  @spec to_json(module()) :: map()
  def to_json(module) do
    %{
      name: name(module),
      description: description(module),
      category: category(module),
      tags: tags(module),
      vsn: vsn(module),
      compensation: compensation(module),
      schema: schema(module),
      output_schema: output_schema(module)
    }
  end
end
