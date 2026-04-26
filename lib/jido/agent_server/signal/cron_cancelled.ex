defmodule Jido.AgentServer.Signal.CronCancelled do
  @moduledoc """
  Synthesized by the `Jido.Agent.Directive.CronCancel` impl after the
  scheduler job is cancelled and the spec map is persisted, then cast
  back to the agent so the cascade callback
  `maybe_track_cron_cancelled/2` can drop the entry from
  `state.cron_specs`, `state.cron_jobs`, `state.cron_monitors`,
  `state.cron_monitor_refs`, and `state.cron_runtime_specs`.

  Per ADR 0019 §1, directives mutate no state. The directive does the
  I/O (cancel the scheduler job + `Process.demonitor` + persist the new
  spec map); the cascade callback observes this synthetic signal and
  rewrites the runtime maps.

  Note: this is distinct from `jido.agent.cron.died` — `cron.cancelled`
  fires when the directive intentionally cancels a job; `cron.died` fires
  when the cron-job process exits (normal or abnormal) and is observed
  by the parent's `:DOWN` monitor.

  ## Fields

  - `:job_id` - Logical cron job id within the agent
  - `:pid` - PID of the cron-job process that was cancelled (or `nil` if
    no runtime job was tracked)
  - `:monitor_ref` - Monitor reference that was cleared (or `nil`)
  """

  use Jido.Signal,
    type: "jido.agent.cron.cancelled",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      job_id: [type: :any, required: true, doc: "Logical cron job id within the agent"],
      pid: [type: :any, doc: "PID of the cancelled cron-job process (nil if untracked)"],
      monitor_ref: [type: :any, doc: "Monitor reference that was cleared (nil if untracked)"]
    ]
end
