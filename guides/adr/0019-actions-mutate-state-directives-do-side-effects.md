# 0019. Actions mutate state; directives are pure side effects

- Status: Accepted
- Implementation: Pending — split across [task 0012](../tasks/0012-delete-state-op-directives.md) (StateOp removal + multi-slice via return shape) and [task 0010](../tasks/0010-pod-runtime-signal-driven-state-machine.md) (Pod runtime under the strict rule).
- Date: 2026-04-26
- Related ADRs: [0014](0014-slice-middleware-plugin.md) (action signature), [0017](0017-pod-mutations-are-signal-driven.md) (where the strict rule first bites), [0018](0018-tagged-tuple-return-shape.md) (return shape that the rule extends)

## Context

Post-ADR 0018 the framework has three reified state-mutation channels in addition to action returns:

1. **`Jido.Agent.StateOp.*` directives** (`SetPath`, `DeletePath`, `SetState`, `ReplaceState`, `DeleteKeys`) — applied by `apply_state_ops/2` before user effects. They're a workaround for the *previous* deep-merge return semantics: when an action's return value was merged into the slice, you couldn't delete a key, so `StateOp.DeletePath` provided an escape hatch. ADR 0014 / task 0002 retired deep-merge: actions now return the **full new slice**. The StateOp escape hatch outlived the limitation it was patching.

2. **Compound directives** like `Jido.Pod.Directive.ApplyMutation` and `Jido.Agent.Directive.SpawnManagedAgent` that combine "do work" (spawn a child, run a wave of starts/stops) with "mutate `agent.state`" (update mutation slice, register child info). The state mutation is hidden inside the directive's `exec/3` body where it isn't visible to readers of the action.

3. **Middleware `ctx.agent` mutation**, e.g. `Persister` staging the thawed agent on `jido.agent.lifecycle.starting`. ADR 0018 §1's 3-tuple `{:error, ctx, reason}` exists specifically because this channel needs to commit even when downstream layers error.

In parallel, the runtime maintains its own state on `%AgentServer.State{}` — `children`, `pending_acks`, `signal_subscribers`, monitors, etc. This is **not domain state**; it's runtime bookkeeping the AgentServer process owns. `handle_call` / `handle_cast` mutate it freely.

The mixing of channels makes "what does this signal do to the agent's slice values?" hard to answer by inspection. A reader has to follow the action's return value, then walk every directive in the effect list, then check every middleware in the chain. The architecture lacks a single answer to "where does state mutation live."

## Decision

### 1. The rule

- **Actions mutate `agent.state` (domain).** The action's return value is the sole source of slice-value changes. Reading the action tells you everything that changes.
- **Directives are pure side effects.** They do work (spawn processes, send shutdown, dispatch signals, persist to disk, write to external systems). They do **not** touch `agent.state`. Their result, if any, comes back as a signal that re-enters the pipeline.
- **`%AgentServer.State{}` (runtime) stays mutable by AgentServer callbacks.** Children tracking, ack/subscribe registration, monitors — all remain `handle_call` / `handle_cast` mutations. This is bookkeeping the process owns and is invisible to user code.
- **Middleware `ctx.agent` mutation is the documented exception** (per ADR 0018 §1). It exists for I/O staging (Persister thaw, future similar concerns) and is the *only* non-action channel for `agent.state` writes.

### 2. What changes in the directive surface

| Directive | Today | After |
|---|---|---|
| `StateOp.SetPath` / `DeletePath` / `SetState` / `ReplaceState` / `DeleteKeys` | Reified state mutations passed in `[directive]` | **Deleted.** Cross-slice writes flow through the action's return shape (see §3). |
| `ApplyMutation` (Pod) | Spawns/stops children + writes `agent.state.pod.mutation` | **Deleted.** Replaced by pure-side-effect `StartNode` / `StopNode` directives + signal-handler actions that own the slice updates (see [ADR 0017](0017-pod-mutations-are-signal-driven.md) §1, Phase 2). |
| `SpawnManagedAgent` | Spawns child + inserts `%ChildInfo{}` into `state.children` | Stays. `state.children` is **runtime** state, not `agent.state` — the rule allows it. |
| `StopChildRuntime` | Sends `:shutdown` + removes from `state.children` | Stays. Same reason. |
| `Emit` / `Reply` / `Schedule` | Side effects (cast, dispatch, cron register) | Stays. Already pure side effects. |
| `%Directive.Error{}` | Logs an error | Stays. Pure I/O. |

### 3. Multi-slice and cross-slice writes

Today, `StateOp.set_path` is the escape hatch for actions that mutate slices they don't own (e.g. `Pod.Actions.Mutate` writes to the `:pod` slice while declaring `path: :app`). Three replacements, in order of preference:

1. **Re-path the action.** If an action mutates the `:pod` slice, declare `path: :pod`. Most existing StateOp callsites are actions that simply chose the wrong `path:` because they could route around it via StateOp.

2. **Multi-slice return shape.** When an action genuinely needs to mutate multiple slices in one transaction, return:

   ```elixir
   {:ok, %Jido.Agent.SliceUpdate{slices: %{pod: pod_slice, audit: audit_slice}}, [side_effects]}
   ```

   The framework applies all named slice updates atomically alongside the action's primary slice. Action declares its primary `path:` as before; secondary slices listed in the `slices` map are explicitly bridged.

3. **Signal cascade.** Action mutates its own slice and emits a signal that another action handles to mutate the second slice. Atomicity is per-pipeline-turn (weaker), but matches strict separation when the two responsibilities don't belong in one action.

The audit suggests almost all current StateOp uses fall into bucket 1 (re-path). Bucket 2 (multi-slice return shape) is the new mechanism for the residual cases. Bucket 3 is a design choice, not a forced workaround.

### 4. Compound-directive split

Any directive that today combines "do work" with "mutate `agent.state`" splits in two:

- A pure side-effect directive that does the work and returns immediately (no `agent.state` change).
- An action — bound to the resulting lifecycle signal in `signal_routes` — that mutates the slice in response.

The Pod state machine in [ADR 0017](0017-pod-mutations-are-signal-driven.md) §1 is the canonical example: `StartNode` spawns and returns; the `jido.agent.child.started` signal triggers a handler action that updates `agent.state.pod.mutation` (specifically `awaiting`, `phase`, possibly emitting the next wave's directives or the terminal `pod.mutate.completed`).

### 5. AgentServer is allowed to mutate its own runtime state freely

`state.children` updates from `handle_call({:adopt_child, ...})` and `maybe_track_child_started/2` are fine. They never write to `agent.state`. This is the bright line: if the field lives on `%AgentServer.State{}` outside the `:agent` key, the runtime owns it. If it lives inside `state.agent.state`, only actions (and the documented middleware exception) write it.

## Consequences

- **Auditability.** Reading an action tells you every domain-state change it produces. Reading the side-effect directive list tells you every I/O it produces. The two lists don't overlap.

- **`Jido.Agent.StateOp` and `Jido.Agent.StateOps` modules deleted.** Plus the `defimpl Jido.AgentServer.DirectiveExec, for: ...` blocks for each StateOp variant. ~5 files plus their tests removed (see [task 0012](../tasks/0012-delete-state-op-directives.md)).

- **Action signature stays the same** — `{:ok, slice, [directive]} | {:error, reason}` from ADR 0018 — but the semantics of `[directive]` tighten: side effects only. The `slice` value position can be a `%SliceUpdate{slices: %{...}}` map for multi-slice writes.

- **The compound `ApplyMutation`-style directives go away.** Pod mutation in particular: today's "ApplyMutation runs everything synchronously and updates the slice"becomes "StartNode/StopNode emit the work, child.started/exit handler-actions advance the slice." This is task 0010's whole point and it lands cleanly only after this rule is documented.

- **Bus plugins (`AutoSubscribeChild`, `AutoUnsubscribeChild`) re-pathed.** They use `StateOp.SetPath`/`DeletePath` to write `[:pod_bus, :subscriptions, tag]` while their action `path:` is unset. Re-path to `:pod_bus` and return the full slice with the desired key set or deleted.

- **`Pod.Actions.Mutate` re-pathed to `:pod`.** Currently writes via StateOp because `path:` falls back to `:app`. After the change, the action declares `path: :pod` and returns the new pod slice value directly with topology, topology_version, and mutation fields all set.

- **Test fixtures that use StateOp to forge runtime state** (`StuckMutationAction` in `mutation_runtime_test.exs`) rewrite as actions that declare the right `path:` and return the forged slice value. The shim becomes naturally testable once [task 0010](../tasks/0010-pod-runtime-signal-driven-state-machine.md) makes mutations multi-mailbox-turn — at which point the shim is deletable entirely.

- **`agent.ex`'s internal `apply_slice_result__/4` keeps building a `%StateOp.SetPath{path: [slice_path], value: new_slice}` op internally.** That's framework infrastructure converting the action's return into the in-memory slice update; it's not a user-facing directive. After this ADR the framework can inline that step (just `put_in(agent.state, [slice_path], new_slice)`) — the `StateOp` struct goes away entirely.

- **Middleware authors gain explicit license to mutate `ctx.agent`** for I/O-staging purposes. The 3-tuple error from ADR 0018 §1 is the protocol; this ADR documents the *why*. New middleware that wants to stage state must opt in deliberately and own the rationale.

## Alternatives considered

**Keep StateOp directives as the canonical cross-slice channel.** Accept that "where does state mutate" has multiple answers; document carefully. Rejected: every audit of "what does this signal do" needs to walk both the action's return AND the directive list, and most StateOp uses are actions that simply mis-declared `path:`. Re-pathing fixes the root cause; keeping StateOp preserves the workaround.

**Allow directives to mutate `agent.state` but only via a typed "state-effect" subset.** Halfway between today and the strict rule: a `%StateEffect{path, value}` shape distinct from a `%SideEffect{...}` shape, both passed in the same directive list. Rejected: it's a renaming exercise. The reader still has to walk two lists. The actual ergonomic win comes from collapsing state mutation into one position (the action's return value).

**Make the AgentServer mutate `state.children` only via actions.** A maximalist version of the rule: even runtime bookkeeping flows through pipeline turns. Rejected: turns `adopt_child` from a 5-line `handle_call` into a "cast a signal, wait for the handler to run" round-trip with no architectural payoff. Runtime state isn't domain state; it doesn't need the same invariants.

**Allow multi-slice action returns by letting `path:` be a list.** `path: [:pod, :audit]` would let the action mutate both slices and return `%{pod: ..., audit: ...}`. Rejected: makes "what slice does this action own" fuzzy in exactly the case (`__resolve_slice_path__`) where the framework needs a single answer for slice scoping. The `%SliceUpdate{}` return shape keeps `path:` single-valued and makes secondary slices an explicit, named exception.

**Defer the rule until task 0012/0010 force it.** Implement those tasks ad hoc and codify the rule afterward. Rejected: the rule is the design constraint that makes those tasks coherent. Without it, task 0010's split of `ApplyMutation` into `StartNode`/`StopNode` + handler action looks like a refactor of convenience; with it, it's the obvious consequence of a stated principle. Document the principle first.
