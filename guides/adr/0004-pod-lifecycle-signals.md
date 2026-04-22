# 0004. Pod reconciliation emits lifecycle signals

- Status: Accepted
- Implementation: Complete
- Date: 2026-04-20
- Related commits: `e624111`

## Context

`Jido.Pod.reconcile/2` runs imperatively: it computes eager-node waves
and drives them to completion through `execute_runtime_plan/6`. The
only externally observable artefact was the synchronous return value
(`{:ok, report} | {:error, report}`) and a `[:jido, :pod, :reconcile]`
telemetry event. Plugins and bus subscribers had nothing to hook —
reconciliation was invisible on the signal pipeline even though the
pod is itself an agent that speaks signals.

That's the asymmetric half of ADR 0001: child liveness (`jido.agent.child.started`,
`.exit`) is fully signalled, but pod-level lifecycle events aren't.

## Decision

`Pod.Runtime.reconcile/2` casts three lifecycle signals to the pod's
AgentServer:

- `jido.pod.reconcile.started` — before waves execute. Data:
  `%{requested: [node_name, ...]}`.
- `jido.pod.reconcile.completed` — on successful reconcile. Data:
  `%{requested: [...], started: [...], failed: [...]}`.
- `jido.pod.reconcile.failed` — on error. Data:
  `%{requested: [...], error: term}`.

Source is `/pod/<state.id>`. Dispatch is best-effort: a failed
`AgentServer.cast` is logged by telemetry but does not abort the
reconcile itself — observability should never break the operation it
observes.

The signals flow through the normal `signal_routes:` pipeline, so
plugins (like `Jido.Pod.BusPlugin`) can handle them exactly the way
they handle `jido.agent.child.started`.

## Consequences

- Reconciliation becomes observable via the same plumbing as child
  lifecycle. A user route `{"jido.pod.reconcile.**", MyAction}`
  catches every phase.
- No telemetry behaviour changes — the existing
  `[:jido, :pod, :reconcile]` span remains.
- Room to add more pod lifecycle signals in the future
  (`jido.pod.mutation.*`, `jido.pod.topology.changed`) following the
  same convention.
- A user's agent-level schema must not conflict with these signal
  types. Reserved prefix: `jido.pod.*`.

## Alternatives considered

- **Only emit telemetry.** Telemetry is synchronous and fast-path — right
  for metrics, wrong for routing/handling. Keeping both costs nothing.
- **Emit signals only via `BusPlugin`, not via `AgentServer.cast`.**
  Would couple reconcile observability to having a bus configured.
  Casting to the pod itself makes these signals available to *any*
  plugin that attaches a `signal_routes:` entry.
