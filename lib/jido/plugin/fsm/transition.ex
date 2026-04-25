defmodule Jido.Plugin.FSM.Transition do
  @moduledoc """
  Transitions the FSM slice to a new state.

  Triggered by a `jido.fsm.transition` signal with `data: %{to: "<next>"}`.
  Validates the requested transition against `slice.transitions`, appends
  a `%{from:, to:}` entry to `slice.history`, and flips `terminal?` if the
  new state is in `slice.terminal_states`.
  """

  use Jido.Action,
    name: "fsm_transition",
    path: :fsm,
    schema:
      Zoi.object(%{
        to: Zoi.string()
      })

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    to = fetch_to(data)
    from = Map.fetch!(slice, :state)
    transitions = Map.get(slice, :transitions, %{})
    allowed = Map.get(transitions, from, [])

    if to in allowed do
      terminal_states = Map.get(slice, :terminal_states, [])
      history = Map.get(slice, :history, []) ++ [%{from: from, to: to}]

      new_slice = %{
        slice
        | state: to,
          history: history,
          terminal?: to in terminal_states
      }

      {:ok, new_slice, []}
    else
      {:error, "invalid FSM transition from #{inspect(from)} to #{inspect(to)}"}
    end
  end

  defp fetch_to(%{to: to}) when is_binary(to), do: to
  defp fetch_to(%{"to" => to}) when is_binary(to), do: to
  defp fetch_to(other), do: raise(ArgumentError, "missing :to in #{inspect(other)}")
end
