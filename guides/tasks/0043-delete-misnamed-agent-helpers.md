---
name: Task 0043 — Delete misnamed `*.Agent` helpers and `Jido.Identity.Profile`
description: Three modules in `lib/` (`Jido.Memory.Agent`, `Jido.Identity.Agent`, `Jido.Thread.Agent`) are named `*.Agent` but do not `use Jido.Agent` — they are pure-function helpers that read and write one slice's portion of `agent.state` directly on a `%Jido.Agent{}` struct, bypassing the signal pipeline. They violate ADR 0019 (state mutation outside actions) and the post-ADR-0023 naming convention. A fourth module, `Jido.Identity.Profile`, exposes typed accessors over `agent.state[:identity].profile` using the same backdoor. Cross-checking callers shows the entire chain is test-only — no production caller exists. Delete all four `lib/` files plus their unit tests, and rewrite the five test files that consumed them: writes go through `cmd/2` dispatching the slice's actions (the production path); reads go directly to `agent.state` and call read-only functions on the data type. The naming-convention violation and the architectural backdoor disappear in one commit. Module names of the data types (`Jido.Memory`, `Jido.Identity`, `Jido.Thread`) and the slice DSL modules are still pre-rename in this task; [task 0044](0044-move-rename-memory-slice.md) onwards renames them.
---

# Task 0043 — Delete misnamed `*.Agent` helpers and `Jido.Identity.Profile`

- Implements: [ADR 0025](../adr/0025-extension-directory-layout.md) §5 (companion cleanup) and ADR 0019 enforcement (no state mutation outside actions).
- Depends on: nothing.
- Blocks: nothing — Phase B tasks ([0044](0044-move-rename-memory-slice.md) onwards) do not require this commit, but it lands first because it removes a state-mutation backdoor that should not survive any further refactor.
- Leaves tree: **green**.

## Context

Three modules under `lib/jido/` carry the name `*.Agent` without
calling `use Jido.Agent`:

- `Jido.Memory.Agent` (`lib/jido/memory/agent.ex`) — helpers over the
  `:memory` slice.
- `Jido.Identity.Agent` (`lib/jido/identity/agent.ex`) — helpers over
  the `:identity` slice.
- `Jido.Thread.Agent` (`lib/jido/thread/agent.ex`) — helpers over the
  `:thread` slice.

Each module is a thin pure-function wrapper that reads from and writes
to one slice's portion of `agent.state` on a `%Jido.Agent{}` struct,
without going through the signal pipeline. The `Jido.Memory.Agent`
moduledoc puts it plainly: "Ergonomic helpers for reading and writing
the `:memory` slice on an `%Jido.Agent{}` value, **without going
through the signal pipeline**."

Two problems with that:

1. **Naming convention violation.** Post-ADR 0023, every `*.Agent`
   module in the tree does `use Jido.Agent`. These three are the only
   exceptions. The
   [migration guide](../../guides/migration-spark-dsl.md) even reuses
   the name `Jido.Memory.Agent` for an example *real agent* —
   advertising the confusion.
2. **State-mutation backdoor.** [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md)
   established that domain state (`agent.state`) is written only
   through actions' return values. The helpers exist precisely to
   write `agent.state` directly: every `put_*` function builds a new
   `%Jido.Agent{}` struct via `%{agent | state: Map.put(agent.state,
   @key, ...)}`. They are an in-tree escape hatch around the
   architecture.

A grep across `lib/`, `test/`, `guides/`, and `livebooks/` shows the
helpers are **test-only ergonomics**:

- 8 test files use them (4 example tests, 1 integration test, plus
  their own 3 unit tests).
- 1 production file uses them: `Jido.Identity.Profile`
  (`lib/jido/identity/profile.ex`), a 37-line module exposing
  `age/1`, `get/3`, `put/3` over `agent.state[:identity].profile`.
  But `Jido.Identity.Profile`'s only callers are
  `test/examples/plugins/identity_slice_test.exs` and its own unit
  test. So the entire chain is test-only.

There is no architectural reason to keep test ergonomics in `lib/`.
The five test callers can be rewritten to use the **production
action-dispatch path** for writes and direct reads against `agent.state`
for queries — which is *more* representative of how production code
exercises slices, not less.

## Goal

After this commit:

- Zero modules named `*.Agent` exist in `lib/jido/` outside actual
  `use Jido.Agent` callsites.
- Zero state-mutation backdoors exist in `lib/`. Every write to
  `agent.state` flows through an action's return value.
- The five test files that previously called the helpers exercise
  the slice's actions through `cmd/2` — same path real callers use.

The slice DSL modules (`Jido.Memory.Slice`, etc.) and the data-type
modules (`Jido.Memory`, etc.) keep their current names in this task.
[Task 0044](0044-move-rename-memory-slice.md) renames them.

## Files to delete

### `lib/jido/memory/agent.ex` — `Jido.Memory.Agent`

Whole file.

### `lib/jido/identity/agent.ex` — `Jido.Identity.Agent`

Whole file.

### `lib/jido/thread/agent.ex` — `Jido.Thread.Agent`

Whole file.

### `lib/jido/identity/profile.ex` — `Jido.Identity.Profile`

Whole file. The module's only `lib/` consumers are itself; both
test callers are listed below for rewrite.

### `test/jido/memory/agent_test.exs`

Tests the deleted module. Whole file.

### `test/jido/identity/agent_test.exs`

Same.

### `test/jido/thread/agent_test.exs`

Same.

### `test/jido/identity/profile_test.exs`

Same.

## Files to rewrite

Pattern: writes dispatch via `cmd/2`; reads are direct against
`agent.state` and call read-only functions on the data type.

```elixir
# before
agent = MemAgent.ensure(agent)
agent = MemAgent.put_in_space(agent, :world, :temperature, 22)
refute MemAgent.has_memory?(agent)
assert MemAgent.get_in_space(agent, :world, :temperature) == 22

# after
{:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Memory.Actions.Ensure, %{}})
{:ok, agent, []} =
  MemoryAgent.cmd(agent, {Jido.Memory.Actions.PutInSpace,
    %{space: :world, key: :temperature, value: 22}})

refute is_map_key(agent.state, :memory) and not is_nil(agent.state[:memory])
assert Jido.Memory.get_in_space(agent.state[:memory], :world, :temperature) == 22
```

The test files already call `cmd/2` to assert the "production-realistic"
behaviour; this rewrite makes the *setup* go through the same path.
Net effect: tests do less hand-rolled state setup, exercise more of
the action layer, and stop relying on a backdoor.

### `test/examples/plugins/memory_slice_test.exs`

Replace every `MemAgent.*` write call with the matching `cmd/2`
dispatch on `MemoryAgent` (the local test agent module). Replace
every read with direct access on `agent.state[:memory]` plus a
`Jido.Memory.*` read function.

The module's own `UpdateWorldAction` already shows the right
shape — it is a `use Jido.Action` that constructs the new memory
struct and returns `{:ok, %{memory: updated_memory}, []}`. Setup
now goes through the same kind of action.

The `MemAgent.delete_space(agent, :world)` test that asserts
`assert_raise ArgumentError, ~r/cannot delete reserved space/` —
the reserved-space check today is in the `Jido.Memory.delete_space/3`
function, so the equivalent test dispatches the `Jido.Memory.Actions.DeleteSpace`
action and asserts `{:error, _}` from `cmd/2`. (Confirm the action
returns `{:error, ArgumentError-shaped}` when the space is reserved;
if it raises today, that's the existing behaviour to preserve.)

### `test/examples/plugins/identity_slice_test.exs`

Three rewrites:

1. `IdentityAgent.ensure(agent)` → `cmd/2` dispatching
   `Jido.Identity.Actions.Ensure` (or whichever ensure action the
   slice ships).
2. `Profile.age(agent)` → `agent.state[:identity].profile[:age]`
   (or `nil` when `agent.state[:identity]` is nil).
3. `Profile.get(agent, :origin)` → `agent.state[:identity].profile[:origin]`.

The `Profile.put/3` calls (if any) become `Jido.Identity.Actions.UpdateProfile`
dispatches.

### `test/examples/plugins/thread_slice_test.exs`

Replace every `ThreadAgent.*` call with the matching `cmd/2`
dispatch (`Jido.Thread.Actions.{Ensure, Append, Clear}`) for writes
and direct `agent.state[:thread]` access for reads.

### `test/examples/persistence/default_slices_persistence_test.exs`

Three aliases to remove (`MemoryAgent`, `IdentityAgent`,
`ThreadAgent`). Same rewrite pattern across the test bodies.

### `test/jido/integration/hibernate_thaw_test.exs`

One alias (`ThreadAgent`). Same pattern. Hibernate/thaw paths
themselves are unchanged — this test was using the helpers only to
build setup state.

## Doc references

### `guides/storage.md`

Search for `Jido.Memory.Agent` (the helper). Either rewrite the
example to use `cmd/2` like the test rewrites, or excise the
example if it duplicates content elsewhere.

### `guides/migration-spark-dsl.md`

The walkthrough names `Jido.Memory.Agent` as a hypothetical *real
agent* module. Pick a different example name (e.g.
`MyApp.SupportAgent`) so the guide does not collide with the deleted
helper's name in readers' minds.

### Older task docs (leave alone)

`guides/tasks/0003-retire-strategy-port-fsm.md`,
`guides/tasks/0005-migrate-intree-plugins.md`,
`guides/tasks/0039-slices-must-declare-schema-and-routes.md` mention
the old helper names. They are historical records of the work that
shipped them. Do not edit.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix test` clean.
- `mix test --include e2e` clean. LM Studio is running locally
  (per repo memory: e2e is part of the local gate on this machine).
- `git grep -nE 'Jido\.(Memory|Identity|Thread)\.Agent\b'` returns
  zero hits in `lib/` and `test/`. Hits remaining in `guides/tasks/`
  (historical records) are expected.
- `git grep -nE 'Jido\.Identity\.Profile\b'` returns zero hits in
  `lib/` and `test/`.
- `git grep -nE '%\{agent \| state:'` shows only the legitimate
  in-tree call sites (`Jido.Scheduler.{extract_staged_cron_specs,
  attach_staged_cron_specs}`, `Jido.Pod.TopologyState.persist_topology`,
  `Jido.Persist.*`) — no new ones, and none in `test/`.

## Out of scope

- Renaming the slice DSL modules (`Jido.Memory.Slice`, etc.) or the
  data-type modules (`Jido.Memory`, etc.). [Task 0044](0044-move-rename-memory-slice.md)
  onwards.
- Moving the slice files into `lib/jido/slices/`. [Task 0044](0044-move-rename-memory-slice.md)
  onwards.
- Adding a `JidoTest.Case` setup helper for the rewritten test
  bodies. If verbosity bites after the rewrite, that's a follow-up
  task; the `cmd/2`-based setup is two lines per call and the
  pattern is uniform.

## Risks

- **A test rewrite asserts subtly different behaviour.** The
  helpers and the actions cover the same surface today, but
  re-checking every assertion against the action's actual return
  shape is the only way to be sure. Plan: rewrite one test file
  first, run it, compare assertions; then mechanical for the rest.
- **A delete-reserved-space test changes its error type.** The
  helper's `delete_space/3` raises `ArgumentError`; the action's
  return shape may be `{:error, ArgumentError.exception(...)}`.
  Check the action's current behaviour and keep the assertion
  aligned.
- **A doc-example reader hits a stale Quickstart.** The
  `guides/migration-spark-dsl.md` rename of the example agent
  module addresses the only known case. Spot-check `README.md`
  and the `lib/jido/agent.ex` moduledoc Quickstart for stragglers.
