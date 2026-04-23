# 0015. Agent start is signal-driven; no thaw distinction

- Status: Proposed
- Implementation: Pending
- Date: 2026-04-23
- Related commits: `ed6abf4`, `be37376`, `30def1e` (carryover from [0007](0007-agent-lifecycle-is-signal-driven.md))
- Supersedes: [0007](0007-agent-lifecycle-is-signal-driven.md)

## Context

[ADR 0007](0007-agent-lifecycle-is-signal-driven.md) identified a real layering problem: thaw was modelled as a thing. Two code paths (`InstanceManager.maybe_thaw` and `Lifecycle.Keyed.maybe_restore_agent_from_storage`), a `restored_from_storage: true` flag leaking into options and state, and four optional agent/plugin callbacks (`checkpoint/2`, `restore/2`, `on_checkpoint/2`, `on_restore/2`) all existed to distinguish "started fresh" from "started from a checkpoint." Every user-facing layer had been taught about thaw.

0007 proposed collapsing this: one start sequence, three lifecycle signals, three plugin callbacks (`to_persistable/1`, `from_persistable/1`, `after_start/1`). The core insight — fresh and resume are indistinguishable — was correct. But [ADR 0014](0014-slice-middleware-plugin.md) settled the extension vocabulary differently than 0007 assumed: **Slices have no callbacks at all.** Persistence shape and start-time setup live on the middleware tier (and, when they need state, in a Plugin's middleware half).

That makes 0007's callback set stale. The lifecycle-signal decision stands; the callback-based implementation of it doesn't. This ADR restates the lifecycle model under 0014's vocabulary: start-time reactions are ordinary signal routes; persistence is middleware; nothing survives on the Slice.

## Decision

**There is no thaw. There is only start. Start is observable as signals. Nothing else is needed.**

An agent's start sequence is identical whether a prior checkpoint exists or not. The checkpoint, if present, is just where the initial slice state comes from instead of schema defaults. The server, the slices, the middleware, and the agent module all run the same code. "Resume" is not a phase any user-level component can observe or branch on.

### Three lifecycle signals

The server emits three signals during its own start:

| Signal | When | Routed by |
|---|---|---|
| `jido.agent.lifecycle.starting` | top of `init/1`, before slice state is loaded | observers (telemetry, traces); middleware that wants to react at raw boot |
| `jido.agent.lifecycle.ready` | after all slice state is loaded, subscriptions re-established, children reconciled, middleware has had its chance to observe | **slices, plugins, observers** |
| `jido.agent.lifecycle.stopping` | top of `terminate/2` | observers; rarely slices |

`ready` is the signal user code is expected to route under normal use. It carries one contractual invariant: from `ready` onward, `state.children` matches the children the agent declares it should have (topology for pods, empty for leaf agents), every cron spec from storage is registered, every subscription has been re-established, and every middleware has observed whatever lifecycle signal it wanted.

These signals are independent of [ADR 0014](0014-slice-middleware-plugin.md)'s `jido.agent.identity.*` family (runtime-identity transitions). Two orthogonal namespaces, both delivered through ordinary `signal_routes`.

### `await_ready/2`

```elixir
@spec await_ready(server(), timeout()) :: :ok | {:error, :timeout}
```

A helper on `Jido.AgentServer` that blocks the caller until `ready` fires, for code (tests, command-line scripts, bootstrap sequences) that wants a synchronous barrier. Shape mirrors [`await_completion/2`](0010-waiting-via-ack-and-subscribe.md) from the pre-0016 surface and `await_child/3` from [ADR 0006](0006-external-sync-uses-signals.md).

There is no `thawing` signal. There is no `initializing` signal distinct from `starting`. Tests and operators who want to see "was this boot a thaw" look at telemetry (which spans boot) or storage logs, not at the agent's signal stream.

### Start-time setup lives in `signal_routes`

Any slice, middleware, or plugin that needs to do work at start routes on a lifecycle signal:

```elixir
defmodule MyApp.ConnectionSlice do
  use Jido.Slice,
    path: :conn,
    schema: Zoi.object(%{endpoint: Zoi.string()}),
    actions: [MyApp.ConnectionSlice.Open],
    signal_routes: [
      {"jido.agent.lifecycle.ready", {MyApp.ConnectionSlice.Open, []}}
    ]
end
```

The `Open` action reads the slice state (which may have been loaded from storage, or may be schema defaults — the action doesn't know and doesn't care), opens the connection, and emits directives. Fresh start and resume produce identical behaviour because both end up at the same slice state.

A Plugin that needs to hold a runtime handle in non-slice state (e.g., an open socket in a process dictionary, an ETS table, or its middleware module's memoized config) observes `lifecycle.ready` in its `on_signal` middleware:

```elixir
defmodule MyApp.SocketPlugin do
  use Jido.Plugin,
    path: :socket,
    schema: Zoi.object(%{endpoint: Zoi.string()}),
    actions: [...]

  @impl Jido.Middleware
  def on_signal(%Signal{type: "jido.agent.lifecycle.ready"} = sig, ctx, next) do
    endpoint = ctx.agent.state.socket.endpoint
    :ok = MyApp.SocketPool.open(self(), endpoint)
    next.(sig, ctx)
  end

  def on_signal(sig, ctx, next), do: next.(sig, ctx)
end
```

No dedicated `after_start/1` callback. The signal is the hook.

### Persistence is middleware, not a Slice callback

A slice's state is serialized verbatim by default, via `Jido.Middleware.Persister` (shipped as part of 0014's standard middleware library). Custom shape transforms (the externalization pattern the old `on_checkpoint/2` served — e.g., a Thread plugin writing memory to external storage and persisting only a pointer) are declared in Persister config, **or** expressed in a Plugin whose middleware half implements the transform.

The old 0007-proposed `to_persistable/1` / `from_persistable/1` callbacks retire. Slices cannot declare persistence shape because Slices have no callbacks per 0014. Plugins that need shape transforms use their middleware half.

### Reconcile runs before `ready`

For pods, `Jido.Pod.Plugin`'s middleware observes `lifecycle.starting` (or routes it to a Slice action) and runs `Jido.Pod.Runtime.reconcile/2`. Reconcile's first step for each topology node is unconditional: **look up the logical id in the registry; if alive, adopt; if not, spawn.** The survivor case and the spawn case converge on "make sure a process with this id exists and I know its pid."

A spawned child runs its own start sequence. It loads its own slice from its own storage (which may be a checkpoint, or may be empty), its own middleware observes its own lifecycle signals, and it emits its own `ready`. Nothing about this differs between fresh start and resume. Each level of a nested hierarchy is self-contained.

Reconcile returns when every node is in `state.children`. The server emits `ready`.

### PIDs are not persisted, ever

Pod topology is a declarative graph of node names and modules. It contains no PIDs. On start, the pod reconciles — registry lookup first, spawn if missing — and `state.children` gets populated with the running pids. This is not a "restore PIDs" step; it is the same step that runs on a fresh start, reaching the same end state from a different initial condition.

Runtime handles that aren't representable by "look up by id and adopt" (open sockets, DB connections, file descriptors) live in middleware observing `lifecycle.ready` and are re-established every start.

### Two thaw paths collapse

`InstanceManager.maybe_thaw` and `Lifecycle.Keyed.maybe_restore_agent_from_storage` both disappear. `AgentServer.init/1` owns loading the slice from storage, using the `storage` and `persistence_key` opts InstanceManager now just passes through. The `restored_from_storage` opt and its state field go away.

## Consequences

- **The agent module shrinks.** No `checkpoint/2`, no `restore/2`. Agent authors write their schema, their actions, their routes; they never see thaw. Fresh and resume are indistinguishable from inside the module.

- **Slices stay pure.** Zero lifecycle callbacks, consistent with 0014. Slices that need start-time side-effects do it through ordinary action routing on `lifecycle.ready` — the mechanism every route goes through.

- **Middleware owns cross-cutting lifecycle.** Plugins with runtime handles or custom persistence shapes express them in `on_signal`. The vocabulary is the one 0014 already introduces; there's nothing lifecycle-specific to learn.

- **Two thaw paths collapse into zero.** `InstanceManager.maybe_thaw` and `Lifecycle.Keyed.maybe_restore_agent_from_storage` disappear; `AgentServer.init/1` owns loading directly.

- **Nested pods compose trivially.** A pod reconciles; for a child that is itself a pod, the spawn triggers that pod's own start, which runs its own reconcile. Each level's `ready` fires independently when that level's topology is live.

- **Survivor adoption is free.** Registry lookup is step one of reconcile. If a child survived the parent's death, its process is in the registry under the same logical id; reconcile adopts it. If not, reconcile spawns. Same code, both cases.

- **Start-time cost is slightly higher.** Every boot runs the storage-load step (returns empty when no checkpoint exists). Every middleware that subscribes to `lifecycle.ready` runs. These are the cases that needed to run anyway; they just run unconditionally now.

- **Breaking change for any plugin using 0007's proposed callbacks.** They never shipped; migration is forward to 0014's vocabulary. Persistence → Persister middleware config or Plugin middleware. Setup → route on `lifecycle.ready`.

- **Breaking change for any plugin still using the pre-0007 `on_checkpoint/2` / `on_restore/2` / `checkpoint/2` / `restore/2` callbacks.** Same migration as above. In-repo plugins (Thread, Memory, Pod) are updated with this ADR.

- **Migration path:**
  1. Add `starting`, `ready`, `stopping` signals + `await_ready/2`. Old callbacks still called internally.
  2. Rewrite the failing thaw/restore tests against `await_ready/2`.
  3. Ship the Persister middleware (0014's standard library).
  4. Migrate in-tree plugins off `on_checkpoint/2`/`on_restore/2` onto Persister config or Plugin middleware.
  5. Migrate plugins that had `mount/2` or start-time logic onto `signal_routes` on `lifecycle.ready`.
  6. Collapse the two thaw paths into AgentServer-owned loading. Remove `restored_from_storage` from opts and state.
  7. Remove the deprecated callbacks.

## Alternatives considered

- **Keep 0007's three-callback contract on Slices.** Smaller break. Rejected: contradicts 0014's "Slice is pure, no callbacks" rule. Resolving that contradiction either forces 0014 to relax (Slice is no longer honestly pure) or forces 0007 to shift its callbacks onto another tier (which is what this ADR does). The shift is the cleaner move.

- **Split `after_start` into `on_fresh_start` and `on_resume`.** Gives code the ability to branch. Immediately produces two code paths for every author to get wrong, and is the exact bug 0007 existed to stop. Rejected again. If middleware needs to branch on persisted state, it inspects its slice.

- **Synchronous `GenServer.start_link` that blocks until ready.** Tempting for call-site ergonomics. Serialises startup across the hierarchy — a pod with ten nodes would take ten times as long to come up. Publish `ready` as a signal; let callers that care opt into waiting.

- **Persist PIDs via node-id resolution on load.** Some systems store pids as serialisable node references and resolve them on thaw. Requires a cluster-aware registry and assumes processes outlive their host. Neither assumption holds here. Persist logical state; re-establish handles from identity on start.

- **Keep the thaw phase; just add a `ready` signal.** Would fix the failing thaw-test regression without committing to a redesign. Leaves every user-facing module knowing about thaw for no reason. Two thaw paths would still exist. Rejected: 0007's original analysis still applies.
