defmodule Jido.Slices.Thread do
  @moduledoc """
  Thread slice — owns the `:thread` key in agent state, mounted as a
  `%Jido.Slices.Thread.State{}` append-only conversation log.

  ## State shape

  Bound to `Jido.Slices.Thread.State.schema/0`. The slice starts as `nil` (lazy-init);
  the first inbound `jido.thread.*` signal materializes a fresh
  `%Jido.Slices.Thread.State{}` via the relevant action.

  ## Routes

      route "jido.thread.ensure", Actions.Ensure
      route "jido.thread.append", Actions.Append
      route "jido.thread.clear",  Actions.Clear

  ## Persistence

  This slice implements `Jido.Persist.Transform` to externalize the thread
  to its small pointer (`%{id, rev}`) on checkpoint. `reinstate/1` is a
  passthrough — actual rehydration happens via the existing
  `Jido.Persist.thaw/3` path.

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Jido.Agent, default_slices: %{thread: false}

      agent do
        name "minimal"
      end
  """

  alias Jido.Slices.Thread.Actions
  alias Jido.Slices.Thread.State

  use Jido.Slice

  slice do
    name "thread"
    description "Append-only conversation history thread for the agent."
    schema State.schema()
  end

  signal_routes do
    route "jido.thread.ensure", Actions.Ensure
    route "jido.thread.append", Actions.Append
    route "jido.thread.clear", Actions.Clear
  end

  capabilities do
    capability :thread
  end

  @thread_section %Spark.Dsl.Section{
    name: :thread,
    describe: "Configuration block contributed by Jido.Slices.Thread.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@thread_section],
    transformers: [Jido.Slices.Thread.Transformers.RegisterContribution]

  @behaviour Jido.Persist.Transform

  @impl Jido.Persist.Transform
  def externalize(%State{id: id, rev: rev}), do: %{id: id, rev: rev}
  def externalize(nil), do: nil
  def externalize(other), do: other

  @impl Jido.Persist.Transform
  def reinstate(value), do: value
end
