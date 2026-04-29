defmodule Jido.Memory.Actions.DeleteFromSpace do
  @moduledoc """
  Removes `key` from a key-value (map) space. Raises when the named space
  is missing or not a map space.
  """

  use Jido.Action

  alias Jido.Memory

  action do
    name "memory_delete_from_space"
    path :memory
    description "Delete a key from a map space."

    schema space: [type: :atom, required: true, doc: "Map space name."],
           key: [type: :any, required: true, doc: "Key to remove."]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, key: key}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, Memory.delete_from_space(memory, name, key), []}
  end

  defp ensure_memory(%Memory{} = memory), do: memory
  defp ensure_memory(_), do: Memory.new()
end
