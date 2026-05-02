defmodule Jido.Slices.Memory.Actions.Ensure do
  @moduledoc """
  Ensures the agent has a `%Jido.Slices.Memory.State{}` mounted at the `:memory` slice.

  When the slice is `nil`, materializes a fresh `Jido.Slices.Memory.State.new/1`. When the
  slice already holds a memory, this action is a no-op.
  """

  use Jido.Action

  alias Jido.Slices.Memory.State

  action do
    name "memory_ensure"
    description "Initialize memory state if missing."

    schema metadata: [type: :map, default: %{}, doc: "Optional metadata for new memory."],
           id: [type: :string, doc: "Optional explicit memory id."]
  end

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    case slice do
      %State{} = memory -> {:ok, memory, []}
      _ -> {:ok, State.new(Map.to_list(data)), []}
    end
  end
end
