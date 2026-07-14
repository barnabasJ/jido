defmodule Jido.Ash.Slice.Persistence do
  @moduledoc false

  alias Jido.Ash.Slice.PersistenceField

  @doc false
  @spec externalize(slice :: term(), fields :: [PersistenceField.t()]) :: term()
  def externalize(slice, fields) when is_map(slice) do
    fields
    |> Enum.filter(&(&1.mode == :durable))
    |> Enum.reduce(%{}, fn %PersistenceField{name: name}, acc ->
      if Map.has_key?(slice, name), do: Map.put(acc, name, Map.fetch!(slice, name)), else: acc
    end)
  end

  def externalize(slice, _fields), do: slice

  @doc false
  @spec reinstate(stored_value :: term(), fields :: [PersistenceField.t()]) :: term()
  def reinstate(stored_value, fields) when is_map(stored_value) do
    durable =
      fields
      |> Enum.filter(&(&1.mode == :durable))
      |> Enum.reduce(%{}, fn %PersistenceField{name: name}, acc ->
        if Map.has_key?(stored_value, name),
          do: Map.put(acc, name, Map.fetch!(stored_value, name)),
          else: acc
      end)

    fields
    |> Enum.filter(&(&1.mode == :restored))
    |> Enum.reduce(durable, &put_restored_default/2)
  end

  def reinstate(stored_value, _fields), do: stored_value

  defp put_restored_default(%PersistenceField{name: name, default: {:static, value}}, acc) do
    Map.put(acc, name, value)
  end

  defp put_restored_default(%PersistenceField{name: name, default: :none, allow_nil?: true}, acc) do
    Map.put(acc, name, nil)
  end

  defp put_restored_default(_field, acc), do: acc
end
