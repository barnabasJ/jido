defmodule Jido.Slices.Memory do
  @moduledoc """
  Memory slice — owns the `:memory` key in agent state, mounted as a
  `%Jido.Slices.Memory.State{}` value with named map / list spaces.

  ## State shape

  Bound to `Jido.Slices.Memory.State.schema/0`. The slice starts as `nil` (lazy-init);
  the first inbound `jido.memory.*` signal materializes a fresh
  `%Jido.Slices.Memory.State{}` via the relevant action.

  ## Routes

  Each `jido.memory.*` signal type maps to a single action under
  `Jido.Slices.Memory.Actions.*`:

      # ensure / put / update / delete
      route "jido.memory.ensure",            Actions.Ensure
      route "jido.memory.put_space",         Actions.PutSpace
      route "jido.memory.update_space",      Actions.UpdateSpace
      route "jido.memory.ensure_space",      Actions.EnsureSpace
      route "jido.memory.delete_space",      Actions.DeleteSpace

      # map space ops
      route "jido.memory.put_in_space",      Actions.PutInSpace
      route "jido.memory.delete_from_space", Actions.DeleteFromSpace

      # list space ops
      route "jido.memory.append_to_space",   Actions.AppendToSpace

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Jido.Agent, default_slices: %{memory: false}

      agent do
        name "minimal"
      end

  ## Persistence

  This bare-minimum default slice keeps memory in-process only and does not
  externalize on checkpoint. If you need a persistence transform, implement
  your own slice that declares `@behaviour Jido.Persist.Transform` and
  override `default_slices: %{memory: MyApp.MyMemorySlice}`.
  """

  alias Jido.Slices.Memory.Actions
  alias Jido.Slices.Memory.State

  use Jido.Slice

  slice do
    name "memory"
    description "Memory state for agent cognition — named map / list spaces."
    schema State.schema()
  end

  signal_routes do
    route "jido.memory.ensure", Actions.Ensure
    route "jido.memory.put_space", Actions.PutSpace
    route "jido.memory.update_space", Actions.UpdateSpace
    route "jido.memory.ensure_space", Actions.EnsureSpace
    route "jido.memory.delete_space", Actions.DeleteSpace
    route "jido.memory.put_in_space", Actions.PutInSpace
    route "jido.memory.delete_from_space", Actions.DeleteFromSpace
    route "jido.memory.append_to_space", Actions.AppendToSpace
  end

  capabilities do
    capability :memory
  end

  @memory_section %Spark.Dsl.Section{
    name: :memory,
    describe: "Configuration block contributed by Jido.Slices.Memory.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@memory_section],
    transformers: [Jido.Slices.Memory.Transformers.RegisterContribution]
end
