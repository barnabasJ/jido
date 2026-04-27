---
name: Task 0028 — Align ADR 0018 §3 with the implemented fire_post_signal_hooks split
description: ADR 0018 §3 specifies fire_post_signal_hooks/3 taking (state, signal, result) where result is the chain's tagged tuple. Code is fire_post_signal_hooks/2 with ack dispatch split out at the call site. The behavior is correct; the ADR text is the part that's stale. Update the ADR.
---

# Task 0028 — Align ADR 0018 §3 with the implemented fire_post_signal_hooks split

- Implements: documentation/spec hygiene. No code change.
- Depends on: nothing.
- Blocks: nothing.
- Leaves tree: green.

## Context

[ADR 0018 §3](../adr/0018-tagged-tuple-return-shape.md) ("Ack delivery reads the chain's outcome, not the directive list") describes the new post-signal hook as `fire_post_signal_hooks/3` taking `(state, signal, result)` where `result` is the chain's tagged tuple. The intent the ADR captures: ack delivery reads the result; subscribers run their selector against state.

In the current code (`lib/jido/agent_server.ex:1931-1932`), the function is arity **2** — `fire_post_signal_hooks(state, signal)` — and only fires subscribers. Ack dispatch happens at the call site (lines 1603/1616, 1686/1691) on the `:ok`/`:error` branch, which already has the result in scope.

The split is correct. Subscribers don't need the result (per the ADR's own paragraph: "Subscribers are unchanged. They always run their selector against state."), and ack delivery already has the result on hand at the branch. But the ADR text reads as if a single `/3` function does both jobs, which doesn't match what shipped.

## Goal

Update ADR 0018 §3 to describe what the code actually does:

- Acks are dispatched directly on the `:ok` / `:error` branch of `process_signal/2` using the chain result that's already in scope.
- `fire_post_signal_hooks/2` only fires subscribers (state-only selectors).
- The two responsibilities are deliberately split because they have different inputs.

## What to change

`guides/adr/0018-tagged-tuple-return-shape.md` §3:

- Drop the `fire_post_signal_hooks/3` signature snippet.
- Rewrite the prose: "Ack delivery reads the chain's tagged tuple at the call site (success/error branch in `process_signal/2`); the post-signal subscriber hook is state-only and unchanged."
- Keep the underlying decision points: source of truth is the tuple, not `%Directive.Error{}`; subscribers don't see errors unless they observe slice fields the action wrote; `AgentServer.call/2` stays unchanged.

## Acceptance criteria

- ADR 0018 §3's signature/arity claim matches `lib/jido/agent_server.ex` exactly.
- No code changes.
- `mix docs` builds clean.
