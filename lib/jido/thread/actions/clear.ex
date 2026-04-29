defmodule Jido.Thread.Actions.Clear do
  @moduledoc """
  Clears all entries from the thread while preserving its identity
  (`id`, `metadata`) and bumping the revision. No-op when the slice has
  not been materialized.
  """

  use Jido.Action

  alias Jido.Thread

  action do
    name "thread_clear"
    path :thread
    description "Reset the thread to an empty state."

    schema []
  end

  @impl true
  def run(%Jido.Signal{}, slice, _opts, _ctx) do
    case slice do
      %Thread{} = thread -> {:ok, Thread.clear(thread), []}
      _ -> {:ok, Thread.new(), []}
    end
  end
end
