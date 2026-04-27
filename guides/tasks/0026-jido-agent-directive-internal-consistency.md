---
name: Task 0026 — `Jido.Agent.Directive` internal consistency: surface Reply, SpawnManagedAgent; complete the Core Directives moduledoc list
description: Three places in lib/jido/agent/directive.ex (alias block, @type core, ## Core Directives moduledoc list) are out of sync with the actual directive surface. Reply and SpawnManagedAgent are missing from the alias and @type core; Cron, CronCancel, Reply, SpawnManagedAgent are missing from the moduledoc list. Fix all three.
---

# Task 0026 — `Jido.Agent.Directive` internal consistency

- Implements: documentation hygiene. No semantic change.
- Depends on: nothing.
- Blocks: nothing.
- Leaves tree: green.

## Context

`lib/jido/agent/directive.ex` has three places that should list the canonical core directives, and they currently disagree:

| Position | Lists | Missing |
|---|---|---|
| `## Core Directives` moduledoc list (lib/jido/agent/directive.ex:41-50) | 9 directives | `Cron`, `CronCancel`, `Reply`, `SpawnManagedAgent` |
| `alias __MODULE__.{...}` block (lib/jido/agent/directive.ex:77-89) | 11 directives | `Reply`, `SpawnManagedAgent` |
| `@type core` (lib/jido/agent/directive.ex:100-110) | 11 directives | `Reply`, `SpawnManagedAgent` |

`Reply` lives at `lib/jido/agent/directive/reply.ex` and `SpawnManagedAgent` is defined inline in `directive.ex` itself. Both are real production directives with `DirectiveExec` impls, helper constructors (`Directive.spawn_managed_agent/4` exists; check whether a `Directive.reply/_` helper exists or should be added), and live test coverage.

## Goal

Make the three lists agree on the same 13 directives:

`Emit, Error, Spawn, SpawnAgent, SpawnManagedAgent, AdoptChild, StopChild, Schedule, RunInstruction, Stop, Cron, CronCancel, Reply`

## Changes

1. **Alias block**: add `Reply` and `SpawnManagedAgent`.
2. **`@type core`**: add `Reply.t()` and `SpawnManagedAgent.t()` (place them where they fit — `SpawnManagedAgent` next to `SpawnAgent`, `Reply` next to `Emit` since both are signal-dispatch directives).
3. **`## Core Directives` moduledoc list**: add rows for the four missing directives. Mirror the prose style already used:

   ```
   * `%Cron{}` - Register a recurring scheduled execution
   * `%CronCancel{}` - Cancel a recurring cron job by id
   * `%Reply{}` - Dispatch a reply signal correlated to a prior request
   * `%SpawnManagedAgent{}` - Spawn an agent via Jido.Agent.InstanceManager (storage-backed lifecycle)
   ```

4. **Helper constructor for `Reply`**: if `Directive.reply/_` doesn't already exist, decide whether to add one (it would mirror `emit/2` / `emit_to_pid/3`). Acceptable to skip if the explicit `%Reply{}` struct construction is the established convention; document that in the moduledoc.

## Acceptance criteria

- All three internal lists in `lib/jido/agent/directive.ex` show the same 13 directives.
- `mix docs` shows no new cross-reference warnings.
- `mix compile --warnings-as-errors` clean.
- `mix test` stays green.

## Out of scope

- The same gap in `guides/directives.md` (the public guide table) — that's [task 0027](0027-refresh-guides-round-2.md).
