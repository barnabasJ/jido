defmodule Jido.Memory.Actions.UpdateSpace do
  @moduledoc """
  Replaces an existing space's value while bumping its revision.

  Unlike `Jido.Memory.Actions.PutSpace`, this action raises when the named
  space is not present — it is the wire-level analogue of
  `Jido.Memory.update_space/4` for a value-shaped (rather than function-shaped)
  signal payload.
  """

  use Jido.Action

  alias Jido.Memory
  alias Jido.Memory.Space

  action do
    name "memory_update_space"
    description "Replace the value of an existing space."

    schema space: [type: :atom, required: true, doc: "Space name to update."],
           value: [
             type: :any,
             required: true,
             doc: "Replacement %Jido.Memory.Space{} value."
           ]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, value: %Space{} = new_space}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, Memory.update_space(memory, name, fn _existing -> new_space end), []}
  end

  defp ensure_memory(%Memory{} = memory), do: memory
  defp ensure_memory(_), do: Memory.new()
end
