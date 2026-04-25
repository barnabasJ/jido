defmodule Jido.Memory.Plugin do
  @moduledoc """
  Default singleton slice for memory state management.

  Owns the `:memory` slice key in agent state. The slice does not initialize
  memory by default — memory is created on demand via
  `Jido.Memory.Agent.ensure/2`.

  ## Singleton

  This slice is a singleton — it cannot be aliased or duplicated. It is
  automatically included as a default plugin for all agents unless explicitly
  disabled:

      use Jido.Agent,
        name: "minimal",
        default_plugins: %{memory: false}

  ## State Key

  Memory is stored at `agent.state.memory` as a `Jido.Memory` struct. Access
  helpers are provided by `Jido.Memory.Agent`.

  ## Persistence

  This bare-minimum default slice keeps memory in-process only and does not
  externalize on checkpoint. If you need persistence, implement your own
  memory slice that declares `@behaviour Jido.Persist.Transform`.
  """

  use Jido.Slice,
    name: "memory",
    path: :memory,
    actions: [],
    singleton: true,
    description: "Memory state management for agent cognitive state.",
    capabilities: [:memory]
end
