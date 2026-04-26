defmodule Jido.AgentServer.Signal.CronRegistered do
  @moduledoc """
  Synthesized by the `Jido.Agent.Directive.Cron` impl after the
  scheduler job spawns and the spec is persisted, then cast back to the
  agent so the cascade callback `maybe_track_cron_registered/2` can
  insert into `state.cron_specs`, `state.cron_jobs`, `state.cron_monitors`,
  `state.cron_monitor_refs`, and `state.cron_runtime_specs`.

  Per ADR 0019 §1, directives mutate no state. The directive does the
  I/O (start the scheduler job + `Process.monitor` + `persist_cron_specs`);
  the cascade callback observes this synthetic signal and writes the
  runtime maps. Subscribers can also observe the registration.

  ## Fields

  - `:job_id` - Logical cron job id within the agent
  - `:pid` - PID of the spawned cron-job process
  - `:monitor_ref` - Monitor reference returned by `Process.monitor/1`
  - `:cron_spec` - The validated `%{cron_expression, message, timezone}` spec
  - `:runtime_spec` - The `%CronRuntimeSpec{}` carrying scheduler details
  """

  use Jido.Signal,
    type: "jido.agent.cron.registered",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      job_id: [type: :any, required: true, doc: "Logical cron job id within the agent"],
      pid: [type: :any, required: true, doc: "PID of the spawned cron-job process"],
      monitor_ref: [type: :any, required: true, doc: "Monitor reference for the cron-job process"],
      cron_spec: [type: :any, required: true, doc: "Validated cron spec map"],
      runtime_spec: [type: :any, required: true, doc: "%CronRuntimeSpec{} carrying scheduler details"]
    ]
end
