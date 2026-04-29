defmodule Jido.Memory.Actions.PutSpace do
  @moduledoc """
  Stores a `%Jido.Memory.Space{}` at the named key, replacing any existing
  space and bumping the container revision. Materializes the slice via
  `Jido.Memory.new/0` when it has not been initialized yet.
  """

  use Jido.Action

  alias Jido.Memory
  alias Jido.Memory.Space

  action do
    name "memory_put_space"
    path :memory
    description "Store a space wholesale at the named key."

    schema space: [type: :atom, required: true, doc: "Space name to set."],
           value: [
             type: :any,
             required: true,
             doc: "%Jido.Memory.Space{} to install at the named key."
           ]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, value: %Space{} = space}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, Memory.put_space(memory, name, space), []}
  end

  defp ensure_memory(%Memory{} = memory), do: memory
  defp ensure_memory(_), do: Memory.new()
end
