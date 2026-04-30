defmodule Jido.Thread.Actions.Ensure do
  @moduledoc """
  Ensures the agent has a `%Jido.Thread{}` mounted at the `:thread` slice.
  Materializes a fresh `Jido.Thread.new/1` when the slice is empty;
  otherwise no-op.
  """

  use Jido.Action

  alias Jido.Thread

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
      %Thread{} = thread -> {:ok, thread, []}
      _ -> {:ok, Thread.new(Map.to_list(data)), []}
    end
  end
end
