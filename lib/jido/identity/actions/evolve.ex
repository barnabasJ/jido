defmodule Jido.Identity.Actions.Evolve do
  @moduledoc """
  Evolves agent identity over simulated time.

  Advances the identity slice through simulated time, accumulating
  experiences and changes over days or years. Operates on the `:identity`
  slice — see `Jido.Identity.Slice`.
  """

  use Jido.Action,
    name: "identity_evolve",
    path: :identity,
    description: "Evolve agent identity over simulated time",
    schema: [
      days: [type: :integer, default: 0, doc: "Days of simulated time to add"],
      years: [type: :integer, default: 0, doc: "Years of simulated time to add"]
    ]

  def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
    identity = slice || Jido.Identity.new()
    evolved = Jido.Identity.evolve(identity, Map.to_list(params))
    {:ok, evolved, []}
  end
end
