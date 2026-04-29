defmodule Jido.Slice.Extension.SchemaTranslate do
  @moduledoc """
  Translates a slice's Zoi `config_schema/0` into a Spark.Options-compatible
  keyword-list schema for use as a host-contribution section.

  v1 covers the in-tree slice shapes:

    * `Zoi.string/1`    -> `:string`
    * `Zoi.atom/1`      -> `:atom`
    * `Zoi.integer/1`   -> `:integer`
    * `Zoi.boolean/1`   -> `:boolean`
    * `Zoi.list/2`      -> `{:list, inner_type}`
    * `Zoi.map/1`       -> `:map`
    * `Zoi.any/1`       -> `:any`
    * `Zoi.optional/1`  -> drops `required: true`
    * `Zoi.default/2`   -> `default: value`
    * Top-level `|> Zoi.transform/2` and `|> Zoi.refine/2` wrappers are
      tolerated — fields are read off the inner object.

  Anything more exotic falls back to `:any`. Slice authors with richer
  shapes override `__jido_host_contribution__/0` manually to write the
  schema by hand.
  """

  @spec translate(term()) :: keyword()
  def translate(nil), do: []

  def translate(%Zoi.Types.Map{fields: fields}) when is_list(fields) do
    Enum.map(fields, fn {key, field_schema} ->
      {key, translate_field(field_schema)}
    end)
  end

  def translate(%Zoi.Types.Keyword{fields: fields}) when is_list(fields) do
    Enum.map(fields, fn {key, field_schema} ->
      {key, translate_field(field_schema)}
    end)
  end

  def translate(_other), do: []

  defp translate_field(field) do
    {default, field} = peel_default(field)

    field
    |> base_type()
    |> maybe_put_default(default)
    |> maybe_put_doc(field)
  end

  defp peel_default(%Zoi.Types.Default{inner: inner, value: value}), do: {{:set, value}, inner}
  defp peel_default(other), do: {:none, other}

  defp base_type(%Zoi.Types.String{}), do: [type: :string]
  defp base_type(%Zoi.Types.Atom{}), do: [type: :atom]
  defp base_type(%Zoi.Types.Integer{}), do: [type: :integer]
  defp base_type(%Zoi.Types.Boolean{}), do: [type: :boolean]
  defp base_type(%Zoi.Types.Any{}), do: [type: :any]

  defp base_type(%Zoi.Types.Array{inner: inner}) do
    case inner_atomic_type(inner) do
      nil -> [type: {:list, :any}]
      type -> [type: {:list, type}]
    end
  end

  defp base_type(%Zoi.Types.Map{fields: fields}) when is_list(fields), do: [type: :keyword_list]
  defp base_type(%Zoi.Types.Map{}), do: [type: :map]
  defp base_type(_other), do: [type: :any]

  defp inner_atomic_type(%Zoi.Types.String{}), do: :string
  defp inner_atomic_type(%Zoi.Types.Atom{}), do: :atom
  defp inner_atomic_type(%Zoi.Types.Integer{}), do: :integer
  defp inner_atomic_type(%Zoi.Types.Boolean{}), do: :boolean
  defp inner_atomic_type(%Zoi.Types.Any{}), do: :any
  defp inner_atomic_type(_), do: nil

  defp maybe_put_default(opts, {:set, value}), do: Keyword.put(opts, :default, value)
  defp maybe_put_default(opts, :none), do: opts

  defp maybe_put_doc(opts, %{meta: %Zoi.Types.Meta{description: doc}}) when is_binary(doc) do
    Keyword.put(opts, :doc, doc)
  end

  defp maybe_put_doc(opts, _), do: opts
end
