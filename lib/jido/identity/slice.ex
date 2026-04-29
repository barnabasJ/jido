defmodule Jido.Identity.Slice do
  @moduledoc """
  Default slice for identity state management.

  Owns the `:identity` slice key in agent state. The slice does not
  initialize an identity by default — identities are created on demand via
  `Jido.Identity.Agent.ensure/2`.

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Jido.Agent,
        name: "minimal",
        default_slices: %{identity: false}

  ## State Key

  The identity is stored at `agent.state.identity` as a `Jido.Identity`
  struct. Access helpers are provided by `Jido.Identity.Agent` and related
  modules.
  """

  use Jido.Slice

  slice do
    name "identity"
    path :identity
    description "Identity state management for agent self-model."
  end

  capabilities do
    capability :identity
  end
end
