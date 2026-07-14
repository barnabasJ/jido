defmodule Jido.Ash.Slice.Info do
  @moduledoc """
  Introspection helpers for Ash resources using `Jido.Ash.Slice`.
  """

  alias Spark.Dsl.Extension

  @section [:jido_slice]

  @doc "Returns the declared slice name."
  @spec name(resource :: module()) :: String.t() | nil
  def name(resource), do: Extension.get_opt(resource, @section, :name)

  @doc "Returns the declared slice description."
  @spec description(resource :: module()) :: String.t() | nil
  def description(resource), do: Extension.get_opt(resource, @section, :description)

  @doc "Returns the declared slice category."
  @spec category(resource :: module()) :: String.t() | nil
  def category(resource), do: Extension.get_opt(resource, @section, :category)

  @doc "Returns the declared slice version."
  @spec vsn(resource :: module()) :: String.t() | nil
  def vsn(resource), do: Extension.get_opt(resource, @section, :vsn)

  @doc "Returns the declared OTP app."
  @spec otp_app(resource :: module()) :: atom() | nil
  def otp_app(resource), do: Extension.get_opt(resource, @section, :otp_app)

  @doc "Returns declared tags."
  @spec tags(resource :: module()) :: [String.t()]
  def tags(resource), do: Extension.get_opt(resource, @section, :tags) || []

  @doc "Returns signal declarations in declaration order."
  @spec signals(resource :: module()) :: [Jido.Ash.Slice.SignalEntry.t()]
  def signals(resource), do: Extension.get_entities(resource, @section)

  @doc "Returns the generated slice module, once a later transformer persists it."
  @spec generated_slice_module(resource :: module()) :: module() | nil
  def generated_slice_module(resource) do
    Extension.get_persisted(resource, :jido_generated_slice_module, nil)
  end

  @doc "Returns generated action modules, once later transformers persist them."
  @spec generated_action_modules(resource :: module()) :: [module()]
  def generated_action_modules(resource) do
    Extension.get_persisted(resource, :jido_generated_action_modules, [])
  end
end
