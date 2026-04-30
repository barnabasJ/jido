defmodule Jido.Thread.Actions.Append do
  @moduledoc """
  Appends one entry (or a list of entries) to the conversation thread.
  Materializes the slice via `Jido.Thread.new/0` when it has not been
  initialized yet.
  """

  use Jido.Action

  alias Jido.Thread

  action do
    name "thread_append"
    description "Append one or more entries to the thread."

    schema entry: [
             type: {:or, [:map, {:list, :map}]},
             required: true,
             doc: "Entry map (or list of entry maps) to append."
           ]
  end

  @impl true
  def run(%Jido.Signal{data: %{entry: entry}}, slice, _opts, _ctx) do
    thread = ensure_thread(slice)
    {:ok, Thread.append(thread, entry), []}
  end

  defp ensure_thread(%Thread{} = thread), do: thread
  defp ensure_thread(_), do: Thread.new()
end
