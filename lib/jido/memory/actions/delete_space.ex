defmodule Jido.Memory.Actions.DeleteSpace do
  @moduledoc """
  Deletes a non-reserved space. Raises `ArgumentError` for reserved spaces
  (`:tasks`, `:world`).
  """

  use Jido.Action

  alias Jido.Memory

  action do
    name "memory_delete_space"
    path :memory
    description "Delete a non-reserved space."

    schema space: [type: :atom, required: true, doc: "Space name to delete."]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, Memory.delete_space(memory, name), []}
  end

  defp ensure_memory(%Memory{} = memory), do: memory
  defp ensure_memory(_), do: Memory.new()
end
