defmodule Jido.AgentServer.Signal.PartitionAssigned do
  @moduledoc """
  Emitted by the AgentServer once its logical partition is established.

  Delivered as `jido.agent.identity.partition_assigned` shortly after
  `State.from_options/3` returns. Routed through the same signal pipeline as
  any other lifecycle signal so plugins/middleware can observe it.

  ## Fields

  - `:partition` - The logical partition the AgentServer was assigned to,
    or `nil` if the agent runs un-partitioned.
  """

  use Jido.Signal,
    type: "jido.agent.identity.partition_assigned",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      partition: [type: :any, required: false, doc: "Logical partition or nil"]
    ]
end
