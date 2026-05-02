defmodule Jido.Slices.Identity.Actions.Evolve do
  @moduledoc """
  Evolves agent identity over simulated time.

  Advances the identity slice through simulated time, accumulating
  experiences and changes over days or years. Operates on the `:identity`
  slice — see `Jido.Slices.Identity`.
  """

  use Jido.Action

  action do
    name "identity_evolve"
    description "Evolve agent identity over simulated time"

    schema days: [type: :integer, default: 0, doc: "Days of simulated time to add"],
           years: [type: :integer, default: 0, doc: "Years of simulated time to add"]
  end

  def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
    identity = slice || Jido.Slices.Identity.State.new()
    evolved = Jido.Slices.Identity.State.evolve(identity, Map.to_list(params))
    {:ok, evolved, []}
  end
end
