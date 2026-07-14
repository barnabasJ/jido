defmodule Jido.Ash.Slice.Info do
  @moduledoc """
  Introspection helpers for Ash resources using `Jido.Ash.Slice`.
  """

  alias Jido.Ash.Slice.StateField
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

  @doc "Returns Ash attributes as stable slice state-field metadata."
  @spec state_fields(resource :: module()) :: [StateField.t()]
  def state_fields(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(&StateField.from_attribute/1)
  end

  @doc "Returns a Zoi object schema derived from Ash resource attributes."
  @spec state_schema(resource :: module()) :: Zoi.schema()
  def state_schema(resource) do
    resource
    |> state_fields()
    |> Map.new(fn %StateField{} = field -> {field.name, field_schema!(field)} end)
    |> Zoi.object()
  end

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

  defp field_schema!(%StateField{} = field) do
    field.type
    |> type_schema!(field.description)
    |> maybe_allow_nil(field.allow_nil?)
    |> maybe_require(field.allow_nil?, field.default)
    |> maybe_default(field.default)
  end

  defp type_schema!({:array, type}, description) do
    type
    |> type_schema!(nil)
    |> Zoi.list(description_opts(description))
  end

  defp type_schema!(Ash.Type.String, description), do: Zoi.string(description_opts(description))
  defp type_schema!(Ash.Type.CiString, description), do: Zoi.string(description_opts(description))
  defp type_schema!(Ash.Type.UUID, description), do: Zoi.string(description_opts(description))
  defp type_schema!(Ash.Type.UUIDv7, description), do: Zoi.string(description_opts(description))
  defp type_schema!(Ash.Type.Integer, description), do: Zoi.integer(description_opts(description))
  defp type_schema!(Ash.Type.Float, description), do: Zoi.float(description_opts(description))
  defp type_schema!(Ash.Type.Boolean, description), do: Zoi.boolean(description_opts(description))
  defp type_schema!(Ash.Type.Atom, description), do: Zoi.atom(description_opts(description))
  defp type_schema!(Ash.Type.Map, description), do: Zoi.map(description_opts(description))
  defp type_schema!(Ash.Type.Term, description), do: Zoi.any(description_opts(description))
  defp type_schema!(Ash.Type.Decimal, description), do: Zoi.decimal(description_opts(description))
  defp type_schema!(Ash.Type.Date, description), do: Zoi.date(description_opts(description))
  defp type_schema!(Ash.Type.Time, description), do: Zoi.time(description_opts(description))
  defp type_schema!(Ash.Type.TimeUsec, description), do: Zoi.time(description_opts(description))

  defp type_schema!(Ash.Type.DateTime, description),
    do: Zoi.datetime(description_opts(description))

  defp type_schema!(Ash.Type.UtcDatetime, description),
    do: Zoi.datetime(description_opts(description))

  defp type_schema!(Ash.Type.UtcDatetimeUsec, description),
    do: Zoi.datetime(description_opts(description))

  defp type_schema!(Ash.Type.NaiveDatetime, description),
    do: Zoi.naive_datetime(description_opts(description))

  defp type_schema!(Ash.Type.Module, description), do: Zoi.atom(description_opts(description))

  defp type_schema!(type, _description) do
    raise ArgumentError,
          "unsupported Ash-backed slice state attribute type #{inspect(type)}"
  end

  defp maybe_allow_nil(schema, true), do: Zoi.nullish(schema)
  defp maybe_allow_nil(schema, false), do: schema

  defp maybe_require(schema, false, :none), do: Zoi.required(schema)
  defp maybe_require(schema, _allow_nil?, _default), do: schema

  defp maybe_default(schema, {:static, default}), do: Zoi.default(schema, default)
  defp maybe_default(schema, _default), do: schema

  defp description_opts(nil), do: []
  defp description_opts(description), do: [description: description]
end
