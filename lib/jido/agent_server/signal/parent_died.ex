defmodule Jido.AgentServer.Signal.ParentDied do
  @moduledoc """
  Emitted by the AgentServer when the agent's logical parent process dies.

  Delivered as `jido.agent.identity.parent_died` from the parent-`:DOWN`
  handler. Independent of the `on_parent_death` policy: `:continue` and
  `:emit_orphan` agents see this signal as the identity transition; the
  legacy `jido.agent.orphaned` signal (alongside, only on `:emit_orphan`)
  carries former-parent details.

  ## Fields

  - `:former_parent` - The `%Jido.AgentServer.ParentRef{}` that has died.
  - `:reason` - Exit reason from the parent process.
  """

  use Jido.Signal,
    type: "jido.agent.identity.parent_died",
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
