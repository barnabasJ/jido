defmodule Jido.Slices.Thread.Actions.Ensure do
  @moduledoc """
  Ensures the agent has a `%Jido.Slices.Thread.State{}` mounted at the `:thread` slice.
  Materializes a fresh `Jido.Slices.Thread.State.new/1` when the slice is empty;
  otherwise no-op.
  """

  use Jido.Action

  alias Jido.Slices.Thread.State

  action do
    name "thread_ensure"
    description "Initialize thread state if missing."

    schema metadata: [
             type: :map,
             default: %{},
             doc: "Optional metadata for newly created thread."
           ],
           id: [type: :string, doc: "Optional explicit thread id."]
  end

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    case slice do
      %State{} = thread -> {:ok, thread, []}
      _ -> {:ok, State.new(Map.to_list(data)), []}
    end
  end
end
