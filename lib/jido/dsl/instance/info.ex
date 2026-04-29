defmodule Jido.Dsl.Instance.Info do
  @moduledoc """
  Introspection surface for `use Jido` (Jido instance) modules.

  Reads the `instance do … end` section options from the instance's
  Spark `dsl_state`.
  """

  alias Spark.Dsl.Extension

  @section [:instance]

  @doc "Returns the OTP application this Jido instance is bound to."
  @spec otp_app(module()) :: atom() | nil
  def otp_app(module), do: Extension.get_opt(module, @section, :otp_app)

  @doc "Returns the storage adapter spec; defaults to ETS when unset."
  @spec storage(module()) :: term()
  def storage(module),
    do: Extension.get_opt(module, @section, :storage, {Jido.Storage.ETS, [table: :jido_storage]})

  @doc "Returns the configured `default_slices` override (if any)."
  @spec default_slices(module()) :: term() | nil
  def default_slices(module), do: Extension.get_opt(module, @section, :default_slices)
end
