# 0001. Pod children boot with parent ref pre-set

- Status: Accepted
- Date: 2026-04-20
- Related commits: `17bbff7`, `4e57d6c`, `68f3ab4`

## Context

Pod children were started via `Jido.Agent.InstanceManager.get/3` and
then `AgentServer.adopt_child/4` — a post-init `GenServer.call` to the
parent pod that in turn called `AgentServer.adopt_parent/2` on the
child. The child booted orphaned (`state.parent == nil`) and had its
parent attached afterwards.

`notify_parent_of_startup/1` — the function that emits
`jido.agent.child.started` back to the parent — runs during the child's
`handle_continue(:post_init, state)` and is guarded on
`state.parent` being a `%ParentRef{}` at that moment. For
pod-spawned children it never matched, so the parent never received the
signal. Plugins and user `signal_routes:` had nothing to hook for "a
child of mine just became ready." Runtime adoption through
`%AdoptChild{}` had the same problem: the directive attached state but
didn't emit the signal.

Net effect: the pod's supervision model was observable in
`state.children` but invisible on the signal pipeline. Anything that
wanted to react to node liveness had no natural place to do it.

## Decision

Pod children will boot with `state.parent` already populated, and
runtime adoption will converge on the same signal.

1. `Jido.Pod.Runtime.ensure_planned_agent_node/10` (and the three
   variants: `_pod_node`, `_agent_node_locally`, `_pod_node_locally`)
   resolve `parent_pid` up front, build a `%ParentRef{}`, and pass it
   via `agent_opts: [parent: ref]` to `InstanceManager.get/3`. The
   child's `State.from_options/3` puts it into `state.parent` at init
   time, so `post_init` emits `jido.agent.child.started` naturally. The
   old post-init `adopt_runtime_child` call is removed.

2. `handle_call({:adopt_parent, ref}, _, state)` on the child side
   calls `notify_parent_of_startup/1` after it attaches the parent, so
   runtime adoption via the `%AdoptChild{}` directive emits the same
   signal that boot-time adoption does. The parent's
   `maybe_track_child_started/2` is idempotent on matching pids, so no
   double-registration happens.

3. All three old helpers (`adopt_runtime_child`,
   `adopt_runtime_child_locally`, `local_adopt_child`) collapse into a
   single `register_child_locally/4` that attaches a monitor and adds a
   `%ChildInfo{}` to `state.children` for the current callback turn.

## Consequences

- Pod children are observable on the signal pipeline. Plugins (like
  `Jido.Pod.BusPlugin`, ADR 0002) can react to node liveness via a
  normal `signal_routes:` entry — no special pod hook needed.
- Runtime adoption (`%AdoptChild{}`) and boot-time adoption (pod spawn)
  now produce the same signal. Client code doesn't need to distinguish.
- `Jido.AgentServer.adopt_child/4` and `adopt_parent/2` are now the
  imperative counterparts to the directive — documented as such rather
  than primary API.
- `Pod.Runtime` net diff was −14 lines after collapsing the three
  helper variants into one.

## Alternatives considered

- **Keep the post-init adoption call and add a separate "child
  adopted" signal.** Would mean two overlapping signals for similar
  events, and plugins would need different routes for boot-time vs
  runtime adoption. Rejected.
- **Start children via a `%SpawnManagedAgent{}` directive from the pod
  runtime itself.** That's what ADR 0003 ultimately arrives at for
  spawn unification, but at this layer we still need the pid
  synchronously for the reconcile report. Rejected in favor of
  passing `parent:` through `agent_opts` directly.
