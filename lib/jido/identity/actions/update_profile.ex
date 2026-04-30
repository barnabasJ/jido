defmodule Jido.Identity.Actions.UpdateProfile do
  @moduledoc """
  Merges a partial profile map into the identity, bumping the revision.
  Materializes the slice via `Jido.Identity.new/0` when it has not been
  initialized yet.
  """

  use Jido.Action

  alias Jido.Identity

  action do
    name "identity_update_profile"
    description "Merge a partial profile map into the identity profile."

    schema profile: [
             type: :map,
             required: true,
             doc: "Partial profile map to merge into the identity."
           ]
  end

  @impl true
  def run(%Jido.Signal{data: %{profile: profile}}, slice, _opts, _ctx) do
    identity = ensure_identity(slice)
    {:ok, Identity.update_profile(identity, profile), []}
  end

  defp ensure_identity(%Identity{} = identity), do: identity
  defp ensure_identity(_), do: Identity.new()
end
