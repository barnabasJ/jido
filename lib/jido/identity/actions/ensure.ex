defmodule Jido.Identity.Actions.Ensure do
  @moduledoc """
  Ensures the agent has a `%Jido.Identity{}` mounted at the `:identity`
  slice. Materializes a fresh `Jido.Identity.new/1` when the slice is
  empty; otherwise no-op.
  """

  use Jido.Action

  alias Jido.Identity

  action do
    name "identity_ensure"
    path :identity
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
      %Identity{} = identity -> {:ok, identity, []}
      _ -> {:ok, Identity.new(Map.to_list(data)), []}
    end
  end
end
