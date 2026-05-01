defmodule Jido.Identity.Slice do
  @moduledoc """
  Identity slice — owns the `:identity` key in agent state, mounted as a
  `%Jido.Identity{}` self-model.

  ## State shape

  Bound to `Jido.Identity.schema/0`. The slice starts as `nil` (lazy-init);
  the first inbound `jido.identity.*` signal materializes a fresh
  `%Jido.Identity{}` via the relevant action.

  ## Routes

      route "jido.identity.ensure",         Actions.Ensure
      route "jido.identity.evolve",         Actions.Evolve
      route "jido.identity.update_profile", Actions.UpdateProfile

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Jido.Agent, default_slices: %{identity: false}

      agent do
        name "minimal"
      end
  """

  alias Jido.Identity
  alias Jido.Identity.Actions

  use Jido.Slice

  slice do
    name "identity"
    description "Identity self-model for agent (lifecycle facts, profile)."
    schema Identity.schema()
  end

  signal_routes do
    route "jido.identity.ensure", Actions.Ensure
    route "jido.identity.evolve", Actions.Evolve
    route "jido.identity.update_profile", Actions.UpdateProfile
  end

  capabilities do
    capability :identity
  end

  @identity_section %Spark.Dsl.Section{
    name: :identity,
    describe: "Configuration block contributed by Jido.Identity.Slice.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@identity_section],
    transformers: [Jido.Identity.Slice.Transformers.RegisterContribution]
end
