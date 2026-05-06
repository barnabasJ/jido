defmodule Jido.Agent.Schema do
  @moduledoc false
  # Utilities for merging agent and slice schemas.
  # Handles Zoi schema introspection and merging.

  @doc """
  Merges the agent's base schema with slice schemas.

  Each slice's schema is nested under its `path`.
  Returns a Zoi object schema with base fields + slice fields.
  """
  @spec merge_with_plugins(any(), [%{path: atom(), schema: term()}]) :: any()
  def merge_with_plugins(nil, []), do: nil
  def merge_with_plugins(base_schema, []), do: base_schema

  def merge_with_plugins(base_schema, slice_specs) when is_list(slice_specs) do
    slice_fields =
      slice_specs
      |> Enum.filter(& &1.schema)
      |> Enum.map(fn spec -> {spec.path, slice_field_schema(spec.schema)} end)
      |> Map.new()

    case base_schema do
      nil ->
        if map_size(slice_fields) == 0 do
          nil
        else
          Zoi.object(slice_fields)
        end

      base ->
        base_fields = extract_fields(base)
        Zoi.object(Map.merge(base_fields, slice_fields))
    end
  end

  # When a slice's schema cannot be initialized from `%{}` (e.g. it has
  # required fields with no defaults, like Memory/Identity/Thread), the
  # slice uses the lazy-nil pattern: the slice value starts as `nil` and
  # the slice's `Ensure`-style action materializes it on demand. Mirror
  # that contract in the merged agent schema by wrapping the slice's
  # field in `Zoi.nullable/1` so state validation accepts the placeholder
  # `nil` until the slice is initialized.
  defp slice_field_schema(schema) do
    case Zoi.parse(schema, %{}) do
      {:ok, _} -> schema
      {:error, _} -> Zoi.nullable(schema)
    end
  end

  @doc """
  Extracts known keys from a Zoi schema.

  Returns a list of atom keys for collision detection.
  """
  @spec known_keys(any()) :: [atom()]
  def known_keys(nil), do: []

  def known_keys(%{__struct__: Zoi.Types.Object, fields: fields}) when is_map(fields) do
    Map.keys(fields)
  end

  def known_keys(%{__struct__: Zoi.Types.Object, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  def known_keys(%{__struct__: Zoi.Types.Map, fields: fields}) when is_map(fields) do
    Map.keys(fields)
  end

  def known_keys(%{__struct__: Zoi.Types.Map, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  def known_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_map(fields) do
    Map.keys(fields)
  end

  def known_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  def known_keys(_), do: []

  @doc """
  Extracts default values from a Zoi schema.

  Walks the schema and extracts defaults from fields.
  Returns a map with default values.
  """
  @spec defaults_from_zoi_schema(any()) :: map()
  def defaults_from_zoi_schema(nil), do: %{}

  def defaults_from_zoi_schema(%{__struct__: Zoi.Types.Object, fields: fields})
      when is_map(fields) do
    extract_defaults_from_fields(fields)
  end

  def defaults_from_zoi_schema(%{__struct__: Zoi.Types.Object, fields: fields})
      when is_list(fields) do
    fields |> Map.new() |> extract_defaults_from_fields()
  end

  def defaults_from_zoi_schema(%{__struct__: Zoi.Types.Map, fields: fields})
      when is_map(fields) do
    extract_defaults_from_fields(fields)
  end

  def defaults_from_zoi_schema(%{__struct__: Zoi.Types.Map, fields: fields})
      when is_list(fields) do
    fields |> Map.new() |> extract_defaults_from_fields()
  end

  def defaults_from_zoi_schema(%{__struct__: Zoi.Types.Struct, fields: fields})
      when is_map(fields) do
    extract_defaults_from_fields(fields)
  end

  def defaults_from_zoi_schema(%{__struct__: Zoi.Types.Struct, fields: fields})
      when is_list(fields) do
    fields |> Map.new() |> extract_defaults_from_fields()
  end

  def defaults_from_zoi_schema(_), do: %{}

  # Private helpers

  defp extract_fields(%{__struct__: Zoi.Types.Object, fields: fields}) when is_map(fields) do
    fields
  end

  defp extract_fields(%{__struct__: Zoi.Types.Object, fields: fields}) when is_list(fields) do
    Map.new(fields)
  end

  defp extract_fields(%{__struct__: Zoi.Types.Map, fields: fields}) when is_map(fields) do
    fields
  end

  defp extract_fields(%{__struct__: Zoi.Types.Map, fields: fields}) when is_list(fields) do
    Map.new(fields)
  end

  defp extract_fields(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_map(fields) do
    fields
  end

  defp extract_fields(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_list(fields) do
    Map.new(fields)
  end

  defp extract_fields(_), do: %{}

  defp extract_defaults_from_fields(fields) when is_map(fields) do
    Enum.reduce(fields, %{}, fn {key, field_schema}, acc ->
      case extract_default(field_schema) do
        {:ok, default} -> Map.put(acc, key, default)
        :none -> acc
      end
    end)
  end

  defp extract_default(%{__struct__: Zoi.Types.Default, value: value}), do: {:ok, value}
  defp extract_default(_), do: :none
end
