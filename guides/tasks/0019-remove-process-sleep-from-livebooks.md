---
name: Task 0019 — Remove `Process.sleep` from livebooks; use `subscribe/4` instead
description: Eliminate every `Process.sleep` in the eight task-0016 livebooks, replacing the wait points with `subscribe/4`-based predicates. The framework's no-polling stance (ADR 0021) applies to demo content as much as production code.
---

# Task 0019 — Remove `Process.sleep` from livebooks; use `subscribe/4` instead

- Implements: docs follow-up to [task 0016](0016-livebook-docs-for-features.md). No production code changes.
- Depends on: [task 0017](0017-slice-owned-routes-and-terminology.md) (the slice-owned-routes refactor edits the same cells; this task should land **after** 0017 to avoid merge conflicts).
- Blocks: nothing.
- Leaves tree: **green** (docs-only).

## Goal

The framework's core stance — codified in [ADR 0021](../adr/0021-no-full-state-no-polling.md) — is that callers don't poll agent state. They subscribe. The task-0016 livebooks ship six `Process.sleep` calls used as crude waits between a `cast/3` and a follow-up `state/3` read. That's exactly the antipattern the ADR rejects. Demo or not, the livebooks teach by example, and a sleep in the demo teaches users that polling-with-a-grace-period is acceptable. It isn't.

Every sleep in the listed livebooks gets replaced with a subscribe-before-cast pattern: register a one-shot subscription whose selector returns `{:ok, _}` when the predicate the sleep was guarding is satisfied, then cast the trigger signal, then `receive` the subscription notification. The pattern is mechanical, well-established (see `mutate_and_wait/3`'s implementation in `lib/jido/pod/mutable.ex` for the reference shape), and produces livebooks that race-correctly on slow machines.

The prose in `actions-and-directives.livemd` that says "the sleep is fine for a one-off demo; in a long-running system it'll race on slow machines" is wrong by ADR 0021 — strike it. Sleeps aren't fine in either context. Replace the messaging with a positive statement of the subscribe-before-cast rule.

## Files to modify

### `guides/call-cast-await-subscribe.livemd`

One sleep at line ~194 in the `cast/3` demo. Replace with subscribe-before-cast:

- Before the cast: `subscribe/4` with `pattern: "counter.inc"`, `once: true`, selector returning `{:ok, s.agent.state.app.count}`.
- After the cast: `receive` the `{:jido_subscription, ref, %{result: {:ok, count}}}` message with a 1-second timeout.
- Drop the `Process.sleep(50)` and the follow-up `state/3` read — the subscription's selector already projects the field.

Cell becomes a clean two-step "subscribe, then cast, then await" pattern that a reader can copy-paste into production code.

### `guides/observability.livemd`

Three sleeps:

1. **~line 283** — trace-propagation cell, after `cast(tpid, attached)`. Replace the silent `subscribe(... fn _ -> :skip end)` + `Process.sleep(100)` + `unsubscribe` with a one-shot `subscribe(... fn _ -> {:ok, :saw_downstream} end, once: true)` followed by a `receive` block. The cell is currently demonstrating that the downstream signal lands; the subscriber should report that it landed instead of silently sleeping.

2. **~line 323** — debug-events buffer cell. After two `cast/3` calls, the cell sleeps then reads `recent_events/2`. Replace with a subscribe whose selector returns `{:ok, :both_processed}` when `s.agent.state.app.count == 3` (1 + 2). Once the subscriber fires, both signals have been processed end-to-end and the debug buffer will have captured them.

3. **~line 351** — `set_debug(true)` toggle cell. After one `cast/3`, sleep then `recent_events/2`. Replace with the same subscribe-before-cast shape as cell #2 but with a one-event predicate.

### `guides/pods.livemd`

One sleep at line ~219 in the `Pod.mutate/3` async demo. Replace with subscribe-before-cast on the pod's mutation slice:

- Before the cast: `subscribe(pod_pid, "**", selector, once: true)` where the selector returns `{:ok, status}` when `s.agent.state.pod.mutation.status` is in `[:completed, :failed]` and `:skip` otherwise.
- After `Pod.mutate/3`: `receive` the notification.
- Drop the sleep + `state/3` read.

Reference shape: `lib/jido/pod/mutable.ex:42-82` — `mutate_and_wait/3`'s subscribe-before-cast pattern is exactly the right template. The pod runtime emits `jido.agent.child.*` lifecycle signals on every node-state transition, so the `"**"` pattern is overly broad — narrow it to `"jido.agent.child.*"` if the lazy-add cascade emits a child signal, or to a tighter pattern if the action emits something more specific. Inspect `Jido.Pod.Mutable.terminal_selector/1` to confirm.

If the lazy-add transitions through `:running → :completed` without ever emitting `child.started` (because no child boots), the `"**"` pattern catches the `Pod.Actions.Mutate` action's own slice update via the agent's natural per-signal selector run. Verify experimentally — if `"**"` doesn't fire, fall back to the prose explanation that `mutate/3` is best paired with `mutate_and_wait/3` and reframe the cell to demonstrate the ack-only return without the post-mutation status check.

### `guides/actions-and-directives.livemd`

No `Process.sleep` calls (the cell that demonstrates the spawn-agent async window already uses subscribe-before-cast correctly). But the prose at ~line 427 says:

> The async window is the directive contract showing through. Production code that needs to reach the post-cascade state subscribes (per ADR 0021, [call-cast-await-subscribe.livemd](call-cast-await-subscribe.livemd)) rather than `Process.sleep`. The sleep is fine for a one-off demo; in a long-running system it'll race on slow machines.

Strike "The sleep is fine for a one-off demo; in a long-running system it'll race on slow machines." Replace with: "Don't use `Process.sleep` to bridge this window — the framework's stance is no polling, no sleep, even in demos. Subscribe before casting and `receive` the subscription notification."

### `guides/getting-started.livemd`

One sleep at line ~186 in the `cast/2` demo (pre-refactor existing file). **Out of scope** — this file's broader rewrite to the post-refactor API is deferred to a separate task per task 0008's deferred follow-up list. Don't fix the sleep here in isolation; the whole cell will be rewritten during the prose refresh.

### `guides/tasks/README.md`

Add a row for task 0019:

```
| [0019](0019-remove-process-sleep-from-livebooks.md) | Remove `Process.sleep` from livebooks; use `subscribe/4` instead | **green** | Documentation correction to task 0016 livebooks (ADR 0021 enforcement) |
```

Update the dependency block: `0017 ← 0019` (depends on the route refactor having landed first to avoid edit conflicts on shared cells).

## Files to create

None.

## Files to delete

None.

## Acceptance

- `grep -n "Process.sleep" guides/*.livemd` returns only `guides/getting-started.livemd` (the explicitly-out-of-scope pre-refactor file). Every other match is gone.
- Each modified cell evaluates top-to-bottom via `mix run scripts/verify_livemd.exs guides/<file>.livemd` without raising and without timing out (selectors fire on real signals, not on a wall-clock guess).
- The prose at `guides/actions-and-directives.livemd:~427` no longer says sleep is acceptable in demos; it states the subscribe-before-cast rule positively.
- `guides/tasks/README.md` indexes task 0019.
- `git diff main -- lib/ test/` is empty — no production code changes.

## Out of scope

- **Touching `guides/getting-started.livemd`.** The pre-refactor `cast` demo will be rewritten in a separate task; fixing the sleep there in isolation would conflict with that broader rewrite.
- **Adding new `subscribe/4` examples to `call-cast-await-subscribe.livemd`.** That livebook already documents the pattern; this task only fixes its own `cast/3` demo cell.
- **Changing the `JidoTest.AgentWait` test helper** or any production code. The fix is purely in livebooks + their accompanying prose.
- **Auditing `actions-and-directives.livemd`'s `LivebookWait` and `RICapture` modules.** They're already subscribe-based. Leave them alone.

## Risks

- **Slow machines + tight timeouts.** Each `receive` block needs a timeout high enough to absorb scheduler jitter on a loaded laptop. Use 1000ms minimum per cell; 2000ms for cells that span multiple cascade hops (the spawn-then-cascade pattern in `actions-and-directives.livemd` already uses 2000ms — match that ceiling).
- **Lazy pod mutations may not emit a single observable signal.** The `mutate/3` async case in `pods.livemd` adds a lazy node, which by design doesn't start a child. The cascade callback that flips `pod.mutation.status` to `:completed` runs as part of the pod-mutate signal's own pipeline turn, so the natural-signal subscribe pattern may not deliver. If experimentation confirms the subscriber never fires, the right fix is to reframe the cell — not to fall back to a sleep. Options: (a) demonstrate `mutate/3` returning the queued ack and stop there, deferring the status read to `mutate_and_wait/3`'s own example; (b) add a non-lazy node so the cascade has a child lifecycle signal to ride.
- **The verifier evaluates cells in series.** A cell that hangs on a never-fired subscribe blocks the whole verifier run — better than a flaky sleep but visible as a hard timeout. Treat verifier hangs as a bug to investigate, not as a reason to add sleeps back.
- **`receive` selectivity.** When a livebook subscribes multiple times in nearby cells, the `receive {:jido_subscription, ^ref, _}` pattern uses pinned refs to avoid mismatching messages — confirm each cell's `ref` is the most recent registration before the `receive` runs.
