defmodule Jido.AgentServer.Signal.LifecycleReady do
  @moduledoc """
  Emitted by the AgentServer once `handle_continue(:post_init, ...)` has
  finished bringing the agent up: signal router built, plugin children
  started, plugin subscriptions live, schedules registered, parent
  binding persisted, parent notified.

  Routed through the middleware chain. By the time `lifecycle.ready`
  fires, any thaw IO performed by the Persister middleware on
  `lifecycle.starting` has completed — observers see the post-thaw
  agent state.

  Slices and plugins can subscribe via `signal_routes:` to perform any
  one-shot post-boot work (warming caches, broadcasting presence, etc).
  """

  use Jido.Signal,
    type: "jido.agent.lifecycle.ready",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: []
end
