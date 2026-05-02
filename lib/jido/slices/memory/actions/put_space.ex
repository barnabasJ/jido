defmodule Jido.Slices.Memory.Actions.PutSpace do
  @moduledoc """
  Stores a `%Jido.Slices.Memory.Space{}` at the named key, replacing any existing
  space and bumping the container revision. Materializes the slice via
  `Jido.Slices.Memory.State.new/0` when it has not been initialized yet.
  """

  use Jido.Action

  alias Jido.Slices.Memory.State
  alias Jido.Slices.Memory.Space

  action do
    name "memory_put_space"
    description "Store a space wholesale at the named key."

    schema space: [type: :atom, required: true, doc: "Space name to set."],
           value: [
             type: :any,
             required: true,
             doc: "%Jido.Slices.Memory.Space{} to install at the named key."
           ]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, value: %Space{} = space}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, State.put_space(memory, name, space), []}
  end

  defp ensure_memory(%State{} = memory), do: memory
  defp ensure_memory(_), do: State.new()
end
