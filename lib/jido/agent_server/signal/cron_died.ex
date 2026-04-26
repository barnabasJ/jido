defmodule Jido.AgentServer.Signal.CronDied do
  @moduledoc """
  Emitted by `handle_cron_job_down/4` when a cron-job process dies — both
  for normal exits and abnormal terminations.

  This signal exists so subscribers can observe the
  `state.cron_jobs[logical_id]` removal that happens in the DOWN
  handler, which would otherwise be invisible to `subscribe/4` (the
  DOWN message doesn't go through `process_signal/2`).

  When the death is abnormal a `jido.agent.cron.restarted` follows once
  the restart timer fires and registration succeeds. Normal exits do
  not trigger a restart.

  ## Fields

  - `:job_id` - Logical cron job id within the agent
  - `:pid` - PID of the cron-job process that exited
  - `:reason` - Exit reason (`:normal`, `:shutdown`, `{:shutdown, _}` are
    treated as normal exits; anything else is abnormal and triggers restart)
  """

  use Jido.Signal,
    type: "jido.agent.cron.died",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      job_id: [type: :any, required: true, doc: "Logical cron job id within the agent"],
      pid: [type: :any, required: true, doc: "PID of the cron-job process that exited"],
      reason: [type: :any, required: true, doc: "Exit reason from the cron-job process"]
    ]
end
