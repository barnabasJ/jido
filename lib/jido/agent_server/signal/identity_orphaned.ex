defmodule Jido.AgentServer.Signal.IdentityOrphaned do
  @moduledoc """
  Emitted by the AgentServer when a child completes the orphan transition
  under `on_parent_death: :emit_orphan`.

  Delivered as `jido.agent.identity.orphaned` immediately after
  `jido.agent.identity.parent_died`. The legacy `jido.agent.orphaned`
  signal (`Jido.AgentServer.Signal.Orphaned`) continues to carry
  flattened former-parent details for action-level routing; this signal
  is the canonical identity-transition marker.

  ## Fields

  - `:former_parent` - The `%Jido.AgentServer.ParentRef{}` that has died.
  - `:reason` - Exit reason from the parent process.
  """

  use Jido.Signal,
    type: "jido.agent.identity.orphaned",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      former_parent: [
        type: :any,
        required: true,
        doc: "%ParentRef{} of the parent that died"
      ],
      reason: [type: :any, required: true, doc: "Exit reason from the parent process"]
    ]
end
