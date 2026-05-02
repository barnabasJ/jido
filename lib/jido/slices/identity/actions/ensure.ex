defmodule Jido.Slices.Identity.Actions.Ensure do
  @moduledoc """
  Ensures the agent has a `%Jido.Slices.Identity.State{}` mounted at the `:identity`
  slice. Materializes a fresh `Jido.Slices.Identity.State.new/1` when the slice is
  empty; otherwise no-op.
  """

  use Jido.Action

  alias Jido.Slices.Identity.State

  action do
    name "identity_ensure"
    description "Initialize identity state if missing."

    schema profile: [
             type: :map,
             default: %{age: nil},
             doc: "Initial profile map for new identities."
           ]
  end

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    case slice do
      %State{} = identity -> {:ok, identity, []}
      _ -> {:ok, State.new(Map.to_list(data)), []}
    end
  end
end
