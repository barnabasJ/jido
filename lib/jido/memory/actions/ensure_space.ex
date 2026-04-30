defmodule Jido.Memory.Actions.EnsureSpace do
  @moduledoc """
  Ensures a named space exists with the supplied default data. The data
  shape selects the space kind: a `map` produces a key-value space, a
  `list` produces an ordered list space. No-op when the space already
  exists.
  """

  use Jido.Action

  alias Jido.Memory

  action do
    name "memory_ensure_space"
    description "Create a space with default data if missing."

    schema space: [type: :atom, required: true, doc: "Space name to ensure."],
           default: [
             type: {:or, [:map, {:list, :any}]},
             default: %{},
             doc: "Default data for the new space (map → kv, list → list)."
           ]
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, default: default}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, Memory.ensure_space(memory, name, default), []}
  end

  defp ensure_memory(%Memory{} = memory), do: memory
  defp ensure_memory(_), do: Memory.new()
end
