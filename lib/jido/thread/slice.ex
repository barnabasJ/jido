defmodule Jido.Thread.Slice do
  @moduledoc """
  Default slice for thread state management.

  Owns the `:thread` slice key in agent state. The slice does not initialize
  a thread by default — threads are attached on demand via
  `Jido.Thread.Agent.ensure/2`.

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Jido.Agent,
        name: "minimal",
        default_slices: %{thread: false}

  ## State Key

  The thread is stored at `agent.state.thread` as a `Jido.Thread` struct.
  Access helpers are provided by `Jido.Thread.Agent`.

  ## Persistence

  When `Jido.Middleware.Persister` is attached, `externalize/1` strips a
  `Jido.Thread` down to the small pointer (`%{id, rev}`) that is written to
  the checkpoint. `reinstate/1` is a passthrough today — actual rehydration
  happens via the existing `Jido.Persist.thaw/3` path, which is collapsed
  into the middleware in a later commit.
  """

  alias Jido.Thread

  use Jido.Slice

  slice do
    name "thread"
    path :thread
    description "Thread state management for agent conversation history."
  end

  capabilities do
    capability :thread
  end

  @behaviour Jido.Persist.Transform

  @impl Jido.Persist.Transform
  def externalize(%Thread{id: id, rev: rev}), do: %{id: id, rev: rev}
  def externalize(nil), do: nil
  def externalize(other), do: other

  @impl Jido.Persist.Transform
  def reinstate(value), do: value
end
