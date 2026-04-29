defmodule Jido.Memory.Actions.AppendToSpace do
  @moduledoc """
  Appends `item` to the end of an ordered (list) space. Raises when the
  named space is missing or not a list space.
  """

  use Jido.Action

  alias Jido.Memory

  action do
    name "memory_append_to_space"
    path :memory
    description "Append an item to a list space."

    schema space: [type: :atom, required: true, doc: "List space name."],
           item: [type: :any, required: true, doc: "Item to append."]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, item: item}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, Memory.append_to_space(memory, name, item), []}
  end

  defp ensure_memory(%Memory{} = memory), do: memory
  defp ensure_memory(_), do: Memory.new()
end
