defmodule Jido.Identity.Plugin do
  @moduledoc """
  Default singleton slice for identity state management.

  Owns the `:identity` slice key in agent state. The slice does not
  initialize an identity by default — identities are created on demand via
  `Jido.Identity.Agent.ensure/2`.

  ## Singleton

  This slice is a singleton — it cannot be aliased or duplicated. It is
  automatically included as a default plugin for all agents unless explicitly
  disabled:

      use Jido.Agent,
        name: "minimal",
        default_plugins: %{identity: false}

  ## State Key

  The identity is stored at `agent.state.identity` as a `Jido.Identity`
  struct. Access helpers are provided by `Jido.Identity.Agent` and related
  modules.
  """

  use Jido.Slice,
    name: "identity",
    path: :identity,
    actions: [],
    singleton: true,
    description: "Identity state management for agent self-model.",
    capabilities: [:identity]
end
