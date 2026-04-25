defmodule Jido.AgentServer.Signal.LifecycleStopping do
  @moduledoc """
  Emitted at the top of `terminate/2` before any other shutdown work.

  Routed through the middleware chain. `Jido.Middleware.Persister`, when
  configured, observes this signal and synchronously hibernates the
  current agent state to storage. Hibernate IO must complete within the
  supervisor's `shutdown:` timeout (default 5_000 ms) — slow storage
  backends require raising the timeout, otherwise the supervisor kills
  the process mid-write and the checkpoint is partial.

  ## Fields

  - `:reason` - The termination reason passed to `terminate/2`.
  """

  use Jido.Signal,
    type: "jido.agent.lifecycle.stopping",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      reason: [type: :any, required: false, doc: "Termination reason"]
    ]
end
