# Architecture Decision Records

Architectural decisions for Jido are recorded here. Each ADR captures
**why** a design is the way it is — the decision, the context that led
to it, and the consequences. Use these when in doubt about why
something is structured the way it is, or as a touchstone before making
changes that reverse an earlier call.

## Convention

- One file per decision, numbered sequentially: `NNNN-kebab-case-title.md`.
- Copy [`template.md`](template.md) for new ADRs.
- Keep ADRs short (< 2 screenfuls). Link to code/commits, don't duplicate them.
- Never rewrite history. Deprecating an old decision? Write a new ADR that
  supersedes it and update the old one's status field.

Two orthogonal fields in every ADR's front matter track its lifecycle:

**`Status`** — has the decision itself been adopted?
- `Proposed` — open for discussion; team hasn't committed to doing this.
- `Accepted` — team has committed; this is how we're doing it.
- `Deprecated` — decision reversed; older behaviour no longer preferred.
- `Superseded by NNNN` — explicit replacement lives in ADR NNNN.

**`Implementation`** — has the code been written?
- `Pending` — no implementation work has started.
- `Partial` — core of the decision is shipped; deferred follow-ups listed
  in the ADR's Consequences section or a companion plan doc.
- `Complete` — all aspects of the ADR are shipped.

A proposed ADR is almost always Pending. An accepted ADR progresses
Pending → Partial → Complete as work lands. `Related commits:` lists
SHAs that implemented the decision (or `—` if none yet).

## Index

| # | Title | Status | Impl |
|---|---|---|---|
| [0001](0001-children-boot-with-parent-ref.md) | Pod children boot with parent ref pre-set | Accepted | Complete |
| [0002](0002-signal-based-request-reply.md) | Request/reply over signals (`Jido.Signal.Call`) | Accepted | Complete |
| [0003](0003-server-state-access-lives-in-directives.md) | Server-state access lives in directives, not actions | Accepted | Complete |
| [0004](0004-pod-lifecycle-signals.md) | Pod reconciliation emits lifecycle signals | Accepted | Complete |
| [0005](0005-agent-domain-as-a-state-slice.md) | Agent domain state is a first-class `state_key` slice | Accepted | Complete |
| [0006](0006-external-sync-uses-signals.md) | External sync uses signals and events, not state-dig or polling | Accepted | Partial |
| [0007](0007-agent-lifecycle-is-signal-driven.md) | Start is the only operation; ready is the only lifecycle signal agents route | Proposed | Pending |
| [0008](0008-flat-layout-removed.md) | Agent flat-layout removed; `:__domain__` slice is the default | Accepted | Complete |
| [0009](0009-inline-signal-processing.md) | Inline signal processing; signals are the only async-completion vehicle | Accepted | Complete |
| [0010](0010-waiting-via-ack-and-subscribe.md) | Waiting on agents uses per-signal ack + subscribe, selector-based | Proposed | Pending |
| [0011](0011-retire-strategy-plugins-are-control-flow.md) | Retire `Strategy`; control-flow patterns live as plugins | Proposed | Pending |
