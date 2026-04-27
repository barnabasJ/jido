defmodule Jido.AgentServer.Signal.CronRestarted do
  @moduledoc """
  Emitted by the `:cron_restart` timer handler after `register_runtime_cron_job/3`
  succeeds in re-registering a cron-job that previously died abnormally.

  The DOWN handler + restart timer don't go through `process_signal/2`,
  so without this synthesized signal there's no `fire_subscribers/2` on
  the `state.cron_jobs[logical_id]` re-population — `subscribe/4`
  consumers would have no way to react. State changes need a
  subscribable channel.

  ## Fields

  - `:job_id` - Logical cron job id within the agent
  - `:pid` - PID of the freshly-spawned cron-job process
  """

  use Jido.Signal,
    type: "jido.agent.cron.restarted",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      job_id: [type: :any, required: true, doc: "Logical cron job id within the agent"],
      pid: [type: :any, required: true, doc: "PID of the freshly-spawned cron-job process"]
    ]
end
