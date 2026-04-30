defmodule Jido.Memory.Actions.PutInSpace do
  @moduledoc """
  Sets `key => value` in a key-value (map) space. Raises when the named
  space is missing or not a map space.
  """

  use Jido.Action

  alias Jido.Memory

  action do
    name "memory_put_in_space"
    description "Set a key in a map space."

    schema space: [type: :atom, required: true, doc: "Map space name."],
           key: [type: :any, required: true, doc: "Key to set."],
           value: [type: :any, required: true, doc: "Value to associate with `key`."]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, key: key, value: value}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, Memory.put_in_space(memory, name, key, value), []}
  end

  defp ensure_memory(%Memory{} = memory), do: memory
  defp ensure_memory(_), do: Memory.new()
end
