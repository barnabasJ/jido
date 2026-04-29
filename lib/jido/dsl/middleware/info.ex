defmodule Jido.Dsl.Middleware.Info do
  @moduledoc """
  Introspection surface for `use Jido.Middleware` modules.

  Reads the optional `middleware do … end` section options from the
  middleware's Spark `dsl_state`.
  """

  alias Spark.Dsl.Extension

  @section [:middleware]

  @doc "Returns the middleware's description."
  @spec description(module()) :: String.t() | nil
  def description(module), do: Extension.get_opt(module, @section, :description)

  @doc "Returns the NimbleOptions schema validating per-registration opts."
  @spec schema(module()) :: keyword()
  def schema(module), do: Extension.get_opt(module, @section, :schema, [])
end
