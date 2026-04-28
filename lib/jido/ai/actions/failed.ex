defmodule Jido.AI.Actions.Failed do
  @moduledoc """
  Handles `"ai.react.failed"` — the in-flight LLM call hit a hard
  transport / API error.

  Settles the slice as `:failed` with the reason. Stale signals
  (`request_id` mismatch) and signals received after the slice has
  already terminated are dropped — a delayed `failed` signal must not
  clobber a fresh run that's started since.

  ADR 0019: pure state mutation. No directives, no I/O.
  """

  use Jido.Action,
    name: "ai_react_failed",
    path: :ai,
    description: "Settle the slice as :failed with the reason.",
    schema: [
      reason: [type: :any, required: true],
      request_id: [type: :string, required: true]
    ]

  @impl true
  def run(%Jido.Signal{data: %{reason: reason, request_id: id}}, slice, _opts, _ctx) do
    cond do
      stale?(slice, id) -> {:ok, slice, []}
      slice.status != :running -> {:ok, slice, []}
      true -> {:ok, %{slice | status: :failed, error: reason}, []}
    end
  end

  defp stale?(%{request_id: current}, id), do: current != id
end
