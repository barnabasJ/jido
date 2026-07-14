defmodule Jido.Ash.Slice.Info do
  @moduledoc """
  Introspection helpers for Ash resources using `Jido.Ash.Slice`.
  """

  alias Jido.Ash.Slice.PayloadField
  alias Jido.Ash.Slice.SignalPayload
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
    |> Map.new(fn %StateField{} = field -> {field.name, field_schema!(field, :state)} end)
    |> Zoi.object()
  end

  @doc "Returns derived signal payload metadata in signal declaration order."
  @spec signal_payloads(resource :: module()) :: [SignalPayload.t()]
  def signal_payloads(resource) do
    Enum.map(signals(resource), fn signal ->
      action = fetch_action!(resource, signal.action)

      %SignalPayload{
        type: signal.type,
        action: signal.action,
        fields: payload_fields(resource, action)
      }
    end)
  end

  @doc "Returns a Zoi object schema for the given signal type."
  @spec signal_payload_schema(resource :: module(), signal_type :: String.t()) :: Zoi.schema()
  def signal_payload_schema(resource, signal_type) do
    resource
    |> signal_payloads()
    |> Enum.find(&(&1.type == signal_type))
    |> case do
      %SignalPayload{} = payload -> payload_schema!(payload)
      nil -> raise ArgumentError, "unknown Ash-backed slice signal #{inspect(signal_type)}"
    end
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

  defp fetch_action!(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      nil -> raise ArgumentError, "missing Ash action #{inspect(action)} on #{inspect(resource)}"
      action -> action
    end
  end

  defp payload_fields(resource, action) do
    argument_fields =
      action.arguments
      |> Enum.filter(& &1.public?)
      |> Enum.map(&PayloadField.from_argument/1)

    accepted_attribute_fields =
      resource
      |> accepted_attributes(action)
      |> Enum.map(&PayloadField.from_attribute/1)

    argument_fields ++ accepted_attribute_fields
  end

  defp accepted_attributes(resource, %{accept: accept}) when is_list(accept) do
    attributes_by_name =
      resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(&{&1.name, &1})

    Enum.map(accept, fn name ->
      Map.fetch!(attributes_by_name, name)
    end)
  end

  defp accepted_attributes(_resource, _action), do: []

  defp payload_schema!(%SignalPayload{} = payload) do
    payload.fields
    |> Map.new(fn %PayloadField{} = field -> {field.name, field_schema!(field, :payload)} end)
    |> Zoi.object()
  end

  defp field_schema!(
         %{
           type: type,
           description: description,
           allow_nil?: allow_nil?,
           default: default
         },
         context
       ) do
    type
    |> type_schema!(description, context)
    |> maybe_allow_nil(allow_nil?)
    |> maybe_require(allow_nil?, default)
    |> maybe_default(default)
  end

  defp type_schema!({:array, type}, description, context) do
    type
    |> type_schema!(nil, context)
    |> Zoi.list(description_opts(description))
  end

  defp type_schema!(Ash.Type.String, description, _context),
    do: Zoi.string(description_opts(description))

  defp type_schema!(Ash.Type.CiString, description, _context),
    do: Zoi.string(description_opts(description))

  defp type_schema!(Ash.Type.UUID, description, _context),
    do: Zoi.string(description_opts(description))

  defp type_schema!(Ash.Type.UUIDv7, description, _context),
    do: Zoi.string(description_opts(description))

  defp type_schema!(Ash.Type.Integer, description, _context),
    do: Zoi.integer(description_opts(description))

  defp type_schema!(Ash.Type.Float, description, _context),
    do: Zoi.float(description_opts(description))

  defp type_schema!(Ash.Type.Boolean, description, _context),
    do: Zoi.boolean(description_opts(description))

  defp type_schema!(Ash.Type.Atom, description, _context),
    do: Zoi.atom(description_opts(description))

  defp type_schema!(Ash.Type.Map, description, _context),
    do: Zoi.map(description_opts(description))

  defp type_schema!(Ash.Type.Term, description, _context),
    do: Zoi.any(description_opts(description))

  defp type_schema!(Ash.Type.Decimal, description, _context),
    do: Zoi.decimal(description_opts(description))

  defp type_schema!(Ash.Type.Date, description, _context),
    do: Zoi.date(description_opts(description))

  defp type_schema!(Ash.Type.Time, description, _context),
    do: Zoi.time(description_opts(description))

  defp type_schema!(Ash.Type.TimeUsec, description, _context),
    do: Zoi.time(description_opts(description))

  defp type_schema!(Ash.Type.DateTime, description, _context),
    do: Zoi.datetime(description_opts(description))

  defp type_schema!(Ash.Type.UtcDatetime, description, _context),
    do: Zoi.datetime(description_opts(description))

  defp type_schema!(Ash.Type.UtcDatetimeUsec, description, _context),
    do: Zoi.datetime(description_opts(description))

  defp type_schema!(Ash.Type.NaiveDatetime, description, _context),
    do: Zoi.naive_datetime(description_opts(description))

  defp type_schema!(Ash.Type.Module, description, _context),
    do: Zoi.atom(description_opts(description))

  defp type_schema!(type, _description, context) do
    raise ArgumentError,
          "unsupported Ash-backed slice #{context_name(context)} type #{inspect(type)}"
  end

  defp context_name(:state), do: "state attribute"
  defp context_name(:payload), do: "payload field"

  defp maybe_allow_nil(schema, true), do: Zoi.nullish(schema)
  defp maybe_allow_nil(schema, false), do: schema

  defp maybe_require(schema, false, :none), do: Zoi.required(schema)
  defp maybe_require(schema, _allow_nil?, _default), do: schema

  defp maybe_default(schema, {:static, default}), do: Zoi.default(schema, default)
  defp maybe_default(schema, _default), do: schema

  defp description_opts(nil), do: []
  defp description_opts(description), do: [description: description]
end
