# Architecture Decision Records

Architectural decisions for Jido are recorded here. Each ADR captures
**why** a design is the way it is — the decision, the context that led
to it, and the consequences. Use these when in doubt about why
something is structured the way it is, or as a touchstone before making
changes that reverse an earlier call.

## Convention

- One file per decision, numbered sequentially: `NNNN-kebab-case-title.md`.
- Copy [`template.md`](template.md) for new ADRs.
- Status is `Proposed`, `Accepted`, `Deprecated`, or `Superseded by NNNN`.
- Keep ADRs short (< 2 screenfuls). Link to code/commits, don't duplicate them.
- Never rewrite history. Deprecating an old decision? Write a new ADR that
  supersedes it and update the old one's status field.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-children-boot-with-parent-ref.md) | Pod children boot with parent ref pre-set | Accepted |
| [0002](0002-signal-based-request-reply.md) | Request/reply over signals (`Jido.Signal.Call`) | Accepted |
| [0003](0003-server-state-access-lives-in-directives.md) | Server-state access lives in directives, not actions | Accepted |
| [0004](0004-pod-lifecycle-signals.md) | Pod reconciliation emits lifecycle signals | Accepted |
| [0005](0005-agent-domain-as-a-state-slice.md) | Agent domain state is a first-class `state_key` slice | Accepted |
| [0006](0006-external-sync-uses-signals.md) | External sync uses signals and events, not state-dig or polling | Accepted |
| [0007](0007-agent-lifecycle-is-signal-driven.md) | Start is the only operation; ready is the only lifecycle signal agents route | Proposed |
