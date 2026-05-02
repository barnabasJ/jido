defmodule Jido.Slices.Memory.Actions.UpdateSpace do
  @moduledoc """
  Replaces an existing space's value while bumping its revision.

  Unlike `Jido.Slices.Memory.Actions.PutSpace`, this action raises when the named
  space is not present — it is the wire-level analogue of
  `Jido.Slices.Memory.State.update_space/4` for a value-shaped (rather than function-shaped)
  signal payload.
  """

  use Jido.Action

  alias Jido.Slices.Memory.Space
  alias Jido.Slices.Memory.State

  action do
    name "memory_update_space"
    description "Replace the value of an existing space."

    schema space: [type: :atom, required: true, doc: "Space name to update."],
           value: [
             type: :any,
             required: true,
             doc: "Replacement %Jido.Slices.Memory.Space{} value."
           ]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, value: %Space{} = new_space}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, State.update_space(memory, name, fn _existing -> new_space end), []}
  end

  defp ensure_memory(%State{} = memory), do: memory
  defp ensure_memory(_), do: State.new()
end
