defmodule Jido.AgentServer.Signal.ChildAdopted do
  @moduledoc """
  Emitted by `handle_call({:adopt_child, ...})` after the child has been
  registered into the parent's `state.children` map.

  This is the parent-side counterpart to `jido.agent.child.started`:
  `ChildStarted` is cast back from a freshly-attached child via
  `notify_parent_of_startup/1` and arrives at the parent asynchronously,
  while `ChildAdopted` fires synchronously at the moment the parent's
  own state mutation lands. Subscribers that need to observe "I just
  adopted a child" with no race window should listen for this signal;
  observers that don't care which side initiated the attachment can
  listen for `jido.agent.child.started`.

  ## Fields

  - `:tag` - Tag the child is registered under
  - `:pid` - PID of the adopted child process
  - `:child_id` - ID of the adopted child agent
  - `:child_module` - Module of the adopted child agent
  - `:child_partition` - Partition of the adopted child agent
  - `:meta` - Metadata attached to the adoption
  """

  use Jido.Signal,
    type: "jido.agent.child.adopted",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      tag: [type: :any, required: true, doc: "Tag assigned to the child"],
      pid: [type: :any, required: true, doc: "PID of the adopted child process"],
      child_id: [type: :string, required: true, doc: "ID of the adopted child agent"],
      child_module: [type: :any, required: true, doc: "Module of the adopted child"],
      child_partition: [type: :any, doc: "Partition of the adopted child"],
      meta: [type: :map, default: %{}, doc: "Metadata attached to the adoption"]
    ]
end
