defmodule Jido.Thread.Plugin do
  @moduledoc """
  Default singleton slice for thread state management.

  Owns the `:thread` slice key in agent state. The slice does not initialize
  a thread by default — threads are attached on demand via
  `Jido.Thread.Agent.ensure/2`.

  ## Singleton

  This slice is a singleton — it cannot be aliased or duplicated. It is
  automatically included as a default plugin for all agents unless explicitly
  disabled:

      use Jido.Agent,
        name: "minimal",
        default_plugins: %{thread: false}

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

  use Jido.Slice,
    name: "thread",
    path: :thread,
    actions: [],
    singleton: true,
    description: "Thread state management for agent conversation history.",
    capabilities: [:thread]

  @behaviour Jido.Persist.Transform

  @impl Jido.Persist.Transform
  def externalize(%Thread{id: id, rev: rev}), do: %{id: id, rev: rev}
  def externalize(nil), do: nil
  def externalize(other), do: other

  @impl Jido.Persist.Transform
  def reinstate(value), do: value
end
