defmodule Jido.Dsl.Sensor.Info do
  @moduledoc """
  Introspection surface for `use Jido.Sensor` modules.

  Each accessor takes the sensor module and reads a field from the
  sensor's Spark `dsl_state`. Replaces the per-sensor hand-rolled
  accessor surface that the `GenerateAccessors` transformer used to
  emit on the sensor module.
  """

  alias Spark.Dsl.Extension

  @section [:sensor]

  @doc "Returns the sensor's name."
  @spec name(module()) :: String.t() | nil
  def name(module), do: Extension.get_opt(module, @section, :name)

  @doc "Returns the sensor's description."
  @spec description(module()) :: String.t() | nil
  def description(module), do: Extension.get_opt(module, @section, :description)

  @doc "Returns the sensor's category."
  @spec category(module()) :: String.t() | nil
  def category(module), do: Extension.get_opt(module, @section, :category)

  @doc "Returns the sensor's tags."
  @spec tags(module()) :: [String.t()]
  def tags(module), do: Extension.get_opt(module, @section, :tags) || []

  @doc "Returns the sensor's version."
  @spec vsn(module()) :: String.t() | nil
  def vsn(module), do: Extension.get_opt(module, @section, :vsn)

  @doc "Returns the Zoi schema for sensor configuration."
  @spec schema(module()) :: term() | nil
  def schema(module), do: Extension.get_opt(module, @section, :schema)
end
