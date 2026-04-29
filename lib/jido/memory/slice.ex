defmodule Jido.Memory.Slice do
  @moduledoc """
  Default slice for memory state management.

  Owns the `:memory` slice key in agent state. The slice does not initialize
  memory by default — memory is created on demand via
  `Jido.Memory.Agent.ensure/2`.

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Jido.Agent,
        name: "minimal",
        default_slices: %{memory: false}

  ## State Key

  Memory is stored at `agent.state.memory` as a `Jido.Memory` struct. Access
  helpers are provided by `Jido.Memory.Agent`.

  ## Persistence

  This bare-minimum default slice keeps memory in-process only and does not
  externalize on checkpoint. If you need persistence, implement your own
  memory slice that declares `@behaviour Jido.Persist.Transform`.
  """

  use Jido.Slice

  slice do
    name "memory"
    path :memory
    description "Memory state management for agent cognitive state."
  end

  capabilities do
    capability :memory
  end
end
