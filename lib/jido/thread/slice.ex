defmodule Jido.Thread.Slice do
  @moduledoc """
  Thread slice — owns the `:thread` key in agent state, mounted as a
  `%Jido.Thread{}` append-only conversation log.

  ## State shape

  Bound to `Jido.Thread.schema/0`. The slice starts as `nil` (lazy-init);
  the first inbound `jido.thread.*` signal materializes a fresh
  `%Jido.Thread{}` via the relevant action.

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

  alias Jido.Thread
  alias Jido.Thread.Actions

  use Jido.Slice

  slice do
    name "thread"
    description "Append-only conversation history thread for the agent."
    schema Thread.schema()
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
    describe: "Configuration block contributed by Jido.Thread.Slice.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@thread_section],
    transformers: [Jido.Thread.Slice.Transformers.RegisterContribution]

  @behaviour Jido.Persist.Transform

  @impl Jido.Persist.Transform
  def externalize(%Thread{id: id, rev: rev}), do: %{id: id, rev: rev}
  def externalize(nil), do: nil
  def externalize(other), do: other

  @impl Jido.Persist.Transform
  def reinstate(value), do: value
end
