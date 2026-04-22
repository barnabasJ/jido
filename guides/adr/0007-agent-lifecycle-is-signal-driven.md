# 0007. Start is the only operation; ready is the only lifecycle signal agents route

- Status: Proposed
- Date: 2026-04-22
- Related commits: TBD (regression exemplified at `d85907f`)
- Implementation plan: [0007-implementation.md](0007-implementation.md)
- Supersedes `TBD` — none yet, but this revision (2026-04-22 afternoon)
  strengthens an earlier draft that distinguished fresh from thaw;
  the final form erases the distinction entirely.

## Context

Six tests in the pod thaw/restore + nested-pod-partition family
(`test/jido/pod/runtime_test.exs`, `test/jido/pod/mutation_runtime_test.exs`)
regressed on 2026-04-21 starting at commit `17bbff7` (ADR 0001:
children boot with parent pre-set). All six share one failure mode:
the test brings a pod back from storage, immediately peeks at
`state.children`, and finds it empty or stale.

`17bbff7` was correct in direction — replacing a post-init
`GenServer.call` to `AgentServer.adopt_child` with a
`jido.agent.child.started` signal emitted from the child's `post_init`
— but it removed a synchronous barrier without adding a replacement.
The child's signal travels back asynchronously, nothing outside the
server knows when the round-trip is complete, and callers peek at
state before it has settled.

Investigating the fix surfaced a deeper layering problem. Thaw is
treated as a distinct phase today, leaked into user-facing surfaces:

- `Jido.Persist` owns byte orchestration.
- `Jido.Agent.InstanceManager.build_child_spec/5` decides whether to
  hand `AgentServer` a thawed struct or nil, flipping a
  `restored_from_storage: true` flag.
- `AgentServer.Lifecycle.Keyed.init` has its *own* fallback thaw path
  that fires when an AgentServer starts with storage configured but
  without a pre-thawed struct. Two code paths, same concern.
- Agent modules optionally implement `checkpoint/2` and `restore/2`.
- Plugin modules optionally implement `on_checkpoint/2` and `on_restore/2`.

Every user-facing layer has been taught about thaw. Every boot splits
into a fresh branch and a resume branch. The regression is the visible
face of the same deeper mistake: we modelled thaw as a thing.

## Decision

**There is no thaw. There is only start.**

An agent's start sequence is identical whether a prior checkpoint
exists or not. The checkpoint, if present, is just where the initial
slice state comes from instead of schema defaults. The server, the
plugins, and the agent module all run the same code. "Resume" is not
a phase any user-level component can observe or branch on.

This collapses the lifecycle to three signals and the plugin contract
to three callbacks, detailed below.

### Lifecycle signals

The server emits three lifecycle signals during its own start:

| Signal | When | Who routes it |
|---|---|---|
| `jido.agent.lifecycle.starting` | top of `init/1` | observers (telemetry, traces) |
| `jido.agent.lifecycle.ready` | after post-init + plugin `after_start` callbacks return | **agents**, observers |
| `jido.agent.lifecycle.stopping` | top of `terminate/2` | observers; rarely agents |

`ready` is the only one an agent module is expected to route under
normal use. It carries one contractual invariant: from `ready` onward,
`state.children` matches the children the agent declares it should
have (topology for pods, empty for leaf agents); every cron spec from
storage is registered; every subscription has been re-established;
every plugin slice has been loaded and its `after_start` has returned.

A new `AgentServer.await_ready/2` helper (shape mirrors
`await_completion/2` and `await_child/3` from ADR 0006) blocks the
caller until that signal fires, for code that wants a synchronous
barrier.

There is no `thawing` signal. There is no `initializing` signal
distinct from `starting`. Tests and operators that want to see "was
this boot a thaw" look at telemetry (which spans boot) or storage
logs, not at the agent's signal stream.

### Plugin contract

Three callbacks. All with safe defaults. None is ever named for
thaw, restore, or checkpoint.

```elixir
@callback to_persistable(slice_state) :: term         # default: identity
@callback from_persistable(term) :: slice_state       # default: identity
@callback after_start(server_state) :: server_state   # default: no-op
```

- `to_persistable` / `from_persistable` are pure shape transforms. The
  plugin declares how its internal runtime shape projects to a
  persistable form and back. Externalisation (Thread plugin's current
  `on_checkpoint/2` behaviour) is expressed by returning
  `{:externalize, pointer}` from `to_persistable` and following the
  pointer in `from_persistable`. The plugin has no way to know *when*
  these are called and doesn't need to.
- `after_start` runs once per server start, after the slice has been
  loaded (either from storage or from schema defaults). This is where
  a plugin does runtime setup: open connections, register timers,
  trigger reconciliation. Fresh vs. resume is invisible; the plugin
  sees the slice state it expects, and the callback runs the same
  either way.

Neither `checkpoint/2` / `restore/2` on agent modules nor
`on_checkpoint/2` / `on_restore/2` on plugin modules survive. They
are removed.

### Reconcile is an `after_start` callback

For pods, `Jido.Pod.Plugin` implements `after_start/1` as a call into
`Jido.Pod.Runtime.reconcile/2`. Reconcile's first step for each
topology node becomes unconditional: **look up the logical id in the
registry; if alive, adopt; if not, spawn.** The survivor case and the
spawn case converge on "make sure a process with this id exists and I
know its pid."

A spawned child runs its own start sequence. It loads its own slice
from its own storage (which may be a checkpoint, or may be empty), it
runs its own plugin `after_start` callbacks (which, for a pod child
that is itself a pod, recursively reconciles its own topology), and
it emits its own `ready`. Nothing about this differs between fresh
start and resume. Each level of a nested hierarchy is self-contained.

Reconcile returns when every node is in `state.children`. The server
emits `ready`.

### PIDs are not persisted, ever

Pod topology is a declarative graph of node names and modules. It
contains no PIDs. On start, the pod reconciles — registry lookup
first, spawn if missing — and `state.children` gets populated with
the running pids. This is not a "restore PIDs" step; it is the same
step that runs on a fresh start, reaching the same end state from a
different initial condition.

Runtime handles that aren't representable by "look up by id and
adopt" (open sockets, DB connections, file descriptors) live in
`after_start` and are re-established every start.

## Consequences

- **The agent module shrinks.** No `checkpoint/2`, no `restore/2`.
  Agent authors write their schema, their actions, their routes; they
  never see thaw. Fresh and resume are indistinguishable from inside
  the module.
- **Plugins shrink correspondingly.** The `on_checkpoint/2` /
  `on_restore/2` pair collapses into `to_persistable/1` /
  `from_persistable/1` (shape transforms). The `after_start/1` hook
  replaces every current use of "do this only on resume" — because
  there is no such thing; either the work is needed every start, or
  it isn't.
- **Two thaw paths collapse into zero.**
  `InstanceManager.maybe_thaw` disappears; so does
  `Lifecycle.Keyed.maybe_restore_agent_from_storage`. `AgentServer.init/1`
  owns loading the slice from storage, using the `storage` and
  `persistence_key` opts InstanceManager now just passes through. The
  `restored_from_storage` opt and its state field go away.
- **The 6 failing tests are explained.** Their assertion
  `state.children.X.pid == X_pid` ran before reconcile had populated
  `state.children`. Under this design, reconcile runs before `ready`;
  the tests move their assertion behind `await_ready/2`. The test
  passing is the invariant's contrapositive: it passes iff the
  invariant holds.
- **Nested pods compose trivially.** A pod reconciles; for a child
  that is itself a pod, the spawn triggers that pod's own start,
  which runs its own reconcile, which may trigger more reconciles
  further down. Each level's `ready` fires independently, when that
  level's topology is live.
- **Survivor adoption falls out for free.** Registry lookup is step
  one of reconcile. If a child survived the parent's death, its
  process is in the registry under the same logical id; reconcile
  adopts it. If not, reconcile spawns. Same code, both cases.
- **Start-time cost is slightly higher.** Every boot runs the
  storage-load step (returns empty when no checkpoint exists). Every
  plugin's `after_start` runs. These are the cases that needed to
  run anyway; they just run unconditionally now. The old "branch on
  resume" code was not faster, it was more complicated.
- **Migration is a breaking change to the agent and plugin
  behaviours.** Phased path:
  1. Add `starting`, `ready`, `stopping` signals + `await_ready/2`.
     Agent and plugin callbacks stay as-is; AgentServer continues to
     call them internally during init.
  2. Rewrite the 6 failing tests against `await_ready/2`.
  3. Introduce `to_persistable/1`, `from_persistable/1`,
     `after_start/1` with defaults. Deprecate the old callbacks.
     Migrate in-tree plugins (Thread plugin, Memory plugin, Pod
     plugin).
  4. Collapse the two thaw paths into AgentServer-owned loading.
     Remove `restored_from_storage` from opts and state.
  5. Remove the deprecated callbacks in a later major release.

## Alternatives considered

- **Keep the thaw phase; add a `ready` signal.** Would fix the
  failing tests without committing to a redesign. Leaves every
  user-facing module knowing about thaw for no reason. Two thaw
  paths would still exist. The invariant "fresh and resume are
  indistinguishable" would still be false at every layer.

- **Synchronous `GenServer.start_link` that blocks until ready.**
  Tempting for call-site ergonomics. Serialises startup across the
  hierarchy — a pod with ten nodes would take ten times as long to
  come up. Makes supervisor restart semantics brittle. Publish
  `ready` as a signal; let callers that care opt into waiting.

- **Persist PIDs via node-id resolution on load.** Some systems
  store pids as serialisable node references and resolve them on
  thaw. Requires a cluster-aware registry and assumes processes
  outlive their host. Neither assumption holds here. Persist
  logical state; re-establish handles from identity on start.

- **Split `after_start` into `on_fresh_start` and `on_resume`.**
  Gives plugins the ability to branch. Immediately produces two code
  paths for every plugin author to get wrong, and is the exact bug
  this ADR exists to stop. If a plugin has different setup per
  branch, that means it's branching on persisted state — which it
  can do inside `after_start` itself by inspecting its slice, no
  callback split needed.
