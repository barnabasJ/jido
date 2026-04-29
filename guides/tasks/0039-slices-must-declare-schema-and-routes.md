---
name: Task 0039 — Every slice declares a state schema and at least one signal route; promote stub slices to real slices
description: Codify "a slice = shape + signal-routed actions + (optional) config DSL" by adding a verifier on `Jido.Dsl.Slice` that requires `schema` (the Zoi shape of the slice's state) AND at least one entry in `signal_routes` (the slice has at least one inbound signal it acts on). Then promote the three framework defaults — `Jido.Memory.Slice`, `Jido.Identity.Slice`, `Jido.Thread.Slice` — to real slices that satisfy the verifier. Each gets a state schema bound to its data module's Zoi schema, an actions module per state-mutation operation (`Memory.Actions.Put`, `EnsureSpace`, `PutInSpace`, `AppendToSpace`, `DeleteFromSpace`, `UpdateSpace`, `DeleteSpace`; `Identity.Actions.Ensure`, `Evolve` (exists), `UpdateProfile`; `Thread.Actions.Ensure`, `Append`, `Clear`), routes wiring those actions to `jido.{memory,identity,thread}.*` signal types, and a small config schema where it earns its weight. The sibling helpers modules (`Jido.{Memory,Identity,Thread}.Agent`) demote to thin adapters that build a `Jido.Signal` and call into `cmd/2` — or are deleted entirely where the action invocation is shorter than the helper.
---

# Task 0039 — Slices must declare schema and routes; promote stub slices

- Implements: [ADR 0014](../adr/0014-slice-middleware-plugin.md) (Slice as composition unit), [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §1 §4.
- Depends on: [task 0037](0037-slice-dsl-cleanup.md) (cleaner slice surface to enforce the rule on).
- Blocks: [task 0041](0041-extensions-contribute-dsl-sections.md) (so when those slices opt into the contribution mechanism, they have something meaningful to contribute).
- Leaves tree: **green**.

## Context

A slice in this framework is supposed to be a composition unit:
schema declaring its state shape, actions declaring its
mutations, signal routes declaring its inputs. Three slices in
tree don't satisfy that contract:

- `lib/jido/memory/slice.ex` — `name`, `path`, `description`,
  `singleton`, `capability :memory`. No schema, no actions, no
  routes.
- `lib/jido/identity/slice.ex` — same shape; one orphan action
  (`Jido.Identity.Actions.Evolve`) that operates on `:identity`
  but is not wired into any route.
- `lib/jido/thread/slice.ex` — same shape; the slice is
  `@behaviour Jido.Persist.Transform` but otherwise inert.

All three are key-reservation modules: they claim a path in
`agent.state` and advertise a capability, then the actual mutation
logic lives in a sibling module called `*.Agent` (e.g.
`Jido.Memory.Agent`) which is **not** a `use Jido.Agent` — it's
just a helpers module of imperative functions over an `%Agent{}`
struct. Read [memory/agent.ex](../../lib/jido/memory/agent.ex) for
the canonical example.

This split is wrong on three axes:

1. The slice has no surface — it advertises a capability but
   declares nothing the agent runtime can dispatch to. A slice with
   no routes is unreachable through the signal pipeline; the only
   way to mutate its state is via the helper module, which bypasses
   middleware, the directive system, and ADR 0019's "actions
   mutate state" rule.
2. The "*.Agent" naming is misleading. Anyone reading
   `Jido.Memory.Agent` reasonably expects a `use Jido.Agent`
   module; it isn't. The name leaks the fact that we never folded
   the helpers into the slice.
3. Three slices in tree violate "a slice = shape + actions + DSL"
   silently. Whatever rule the framework wants to ship is
   undermined by the fact that its own defaults break it.

## Goal

After this commit:

1. **`Jido.Dsl.Slice` enforces the contract** via a verifier:
   - `schema` must be present in the `slice do … end` section
     (anything other than `nil` / `[]` / empty Zoi.object).
   - `signal_routes` must have at least one route entry.
   The verifier raises a `Spark.Error.DslError` at the offending
   slice's compile time naming the missing piece.
2. **The three default slices satisfy the contract.** Each gets:
   - `schema:` bound to its data module's `schema/0`.
   - One action module per mutation, declared with `use Jido.Action`
     and routed.
   - Routes for every action, in the slice's `signal_routes do
     … end` block.
3. **The sibling `*.Agent` helpers modules collapse.** The pure
   read functions stay (or move into the data module). The
   mutation functions either:
   - Become a thin one-line adapter that calls the slice's action
     via `cmd/2`, or
   - Are deleted because the slice's action is the canonical entry
     point.

The behaviour difference users will notice:

```elixir
# Before
agent = Jido.Memory.Agent.put_in_space(agent, :world, :temperature, 22)

# After
{:ok, agent, _directives} =
  agent
  |> MyAgent.cmd({Jido.Memory.Actions.PutInSpace, %{space: :world, key: :temperature, value: 22}})
```

The helpers can stay as adapters where the brevity matters (e.g.
`Memory.put_in_space/4` builds the `cmd/2` call), but they're
implemented through the slice rather than around it.

## Files to modify

### `lib/jido/dsl/slice/verifiers/has_schema_and_routes.ex` (new)

```elixir
defmodule Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutes do
  @moduledoc """
  Enforces "a slice = shape + signal-routed actions". Every slice must
  declare a `schema:` in its `slice do … end` section and at least one
  entry in `signal_routes do … end`.
  """

  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    schema = Verifier.get_option(dsl_state, [:slice], :schema)
    routes = Verifier.get_entities(dsl_state, [:signal_routes])

    cond do
      schema in [nil, []] ->
        {:error,
         Spark.Error.DslError.exception(
           message: "Slice must declare a `schema:` …",
           path: [:slice, :schema]
         )}

      routes == [] ->
        {:error,
         Spark.Error.DslError.exception(
           message: "Slice must declare at least one route …",
           path: [:signal_routes]
         )}

      true ->
        :ok
    end
  end
end
```

Wire into `Jido.Dsl.Slice`'s `verifiers:` list (after
`GenerateAccessors`).

### `lib/jido/memory/slice.ex`

```elixir
defmodule Jido.Memory.Slice do
  @moduledoc """
  Memory slice — owns the `:memory` key in agent state, mounted as a
  `%Jido.Memory{}` value with named spaces.
  """

  alias Jido.Memory
  alias Jido.Memory.Actions

  use Jido.Slice

  slice do
    name "memory"
    path :memory
    description "Memory state for agent cognition — named map / list spaces."
    schema Memory.schema()
  end

  signal_routes do
    route "jido.memory.ensure", Actions.Ensure
    route "jido.memory.put_space", Actions.PutSpace
    route "jido.memory.update_space", Actions.UpdateSpace
    route "jido.memory.ensure_space", Actions.EnsureSpace
    route "jido.memory.delete_space", Actions.DeleteSpace
    route "jido.memory.put_in_space", Actions.PutInSpace
    route "jido.memory.delete_from_space", Actions.DeleteFromSpace
    route "jido.memory.append_to_space", Actions.AppendToSpace
  end

  capabilities do
    capability :memory
  end
end
```

### `lib/jido/memory/actions/*` (new)

One file per action, each `use Jido.Action`, returning `{:ok,
new_slice}` per ADR 0019. The action body delegates to a function
in `Jido.Memory` (the data module) which does the pure update —
the action is a thin signal handler.

Example:

```elixir
defmodule Jido.Memory.Actions.PutInSpace do
  use Jido.Action

  action do
    name "memory_put_in_space"
    path :memory
    description "Set a key in a map space."
    schema space: [type: :atom, required: true],
           key: [type: :any, required: true],
           value: [type: :any]
  end

  def run(%Jido.Signal{data: %{space: space, key: key, value: value}}, slice, _opts, _ctx) do
    {:ok, Memory.put_in_space(slice, space, key, value)}
  end
end
```

(Where `Memory.put_in_space/4` is the pure function — adapted from
the current `Jido.Memory.Agent.put_in_space/4` but operating on a
`%Memory{}` not a `%Agent{}`.)

Repeat for `Ensure`, `PutSpace`, `UpdateSpace`, `EnsureSpace`,
`DeleteSpace`, `DeleteFromSpace`, `AppendToSpace`.

### `lib/jido/memory.ex`

Move the pure update functions from `Jido.Memory.Agent` into
`Jido.Memory` itself (the data module). The data module already
owns `new/1`, `schema/0`, `reserved_spaces/0`; absorbing the
mutation primitives keeps the Memory data type self-contained.

### `lib/jido/memory/agent.ex`

Two options — pick the smaller one for each function:

- Where the helper is short (1–2 lines), delete it. Callers move to
  `MyAgent.cmd(agent, {Jido.Memory.Actions.X, params})`.
- Where the helper is a true ergonomic win (e.g. the
  `Memory.Agent.put_in_space/4` shorthand for a 3-arg signal), keep
  it but rewrite to build the signal and call `cmd/2`. Audit
  callers — most of `lib/` and `test/` will switch to the action
  shape, leaving few helper survivors.

Realistic outcome: the helpers module shrinks substantially or
disappears. If it disappears, also delete `test/jido/memory/agent_test.exs`
and migrate its assertions into the per-action tests under
`test/jido/memory/actions/*`.

### `lib/jido/identity/slice.ex` — same treatment

```elixir
defmodule Jido.Identity.Slice do
  alias Jido.Identity
  alias Jido.Identity.Actions

  use Jido.Slice

  slice do
    name "identity"
    path :identity
    description "Identity self-model for the agent."
    schema Identity.schema()
  end

  signal_routes do
    route "jido.identity.ensure", Actions.Ensure
    route "jido.identity.evolve", Actions.Evolve
    route "jido.identity.update_profile", Actions.UpdateProfile
  end

  capabilities do
    capability :identity
  end
end
```

`Jido.Identity.Actions.Evolve` already exists; needs only to be
included in the routes (it currently is unrouted). Add `Ensure` and
`UpdateProfile`. Delete the helpers in `Jido.Identity.Agent` per
the same rule.

### `lib/jido/thread/slice.ex` — same treatment

```elixir
defmodule Jido.Thread.Slice do
  alias Jido.Thread
  alias Jido.Thread.Actions

  use Jido.Slice

  slice do
    name "thread"
    path :thread
    description "Conversation history thread for the agent."
    schema Thread.schema()
  end

  signal_routes do
    route "jido.thread.ensure", Actions.Ensure
    route "jido.thread.append", Actions.Append
    route "jido.thread.clear", Actions.Clear
  end

  capabilities do
    capability :thread
  end

  @behaviour Jido.Persist.Transform
  # …
end
```

The `@behaviour Jido.Persist.Transform` and its `externalize/1` /
`reinstate/1` callbacks stay — that's a separate concern (slice
participating in checkpointing).

Add the actions under `lib/jido/thread/actions/*`. Delete the
helpers in `Jido.Thread.Agent` per the same rule.

### Tests

Each promoted slice gets per-action tests:

- `test/jido/memory/actions/put_in_space_test.exs`, etc. — assert
  the action operates on a fresh `%Memory{}` and produces the
  expected new memory.
- `test/jido/memory/slice_test.exs` — refresh to test the slice's
  routes resolve to the right actions; remove assertions about the
  old stub shape.
- `test/jido/memory/agent_test.exs` — either delete (if helpers
  are deleted) or rewrite to test the few surviving adapter
  helpers.
- Same for `identity` and `thread`.

Existing default-slices tests (`test/jido/agent/default_slices_test.exs`,
`test/jido/agent/slices_attachment_test.exs`,
`test/examples/plugins/{memory,identity,thread,default_slice_override}_slice_test.exs`)
need a refresh: assertions about the slice's `manifest.actions` /
`signal_routes/0` shape change. The assertions about *attachment*
(slice X is in `slice_instances/0`) should still pass.

### Files to delete

- `lib/jido/memory/agent.ex` (most likely; possibly stays as a
  small shim if a few helpers earn it).
- `lib/jido/identity/agent.ex` (same).
- `lib/jido/thread/agent.ex` (same).

If a helper module survives, rename it to something accurate —
`Jido.Memory.Actions` is already taken (the namespace for actions),
so leave the file as `*.Agent` if you keep it but document that
it's an ergonomic adapter, not a Jido agent. Better: fold any
surviving helper into the data module (`Jido.Memory`) and delete
the file.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean (the FULL suite — no exclusions).
- `mix test --include e2e` clean.
- A scaffold slice that omits `schema:` raises with a
  `Spark.Error.DslError` citing the missing schema. Add a regression
  test for this.
- A scaffold slice that has `schema:` but no routes raises with the
  same exception type and a different message. Add a regression
  test.
- The three promoted slices are functional end-to-end: a fresh
  agent that mounts `Jido.Memory.Slice` can `cmd(agent, {Memory.Actions.PutInSpace, …})`
  and the resulting `agent.state.memory.spaces[:world]` reflects
  the mutation. Add a test per slice.

## Out of scope

- **Removing the `default_slices:` machinery.** The three slices
  remain default-attached; users who don't want them can still
  pass `default_slices: false` or `default_slices: %{memory: false}`.
  Whether default-attaching three slices is the right framework
  posture is a separate conversation; not litigated here.
- **The `config_schema` for these slices.** Memory, Identity, and
  Thread don't grow per-host config in this commit (no `backend`,
  `namespace`, etc.). When a user case surfaces, add the
  config_schema in a follow-up alongside the contribution
  mechanism in [task 0041](0041-extensions-contribute-dsl-sections.md).
- **Renaming `Jido.{Memory,Identity,Thread}.Agent`.** If we keep
  any of those modules as a thin shim, leave the name; if the
  module is fully deleted there's nothing to rename. A new "what
  do we call the data module's helper namespace" naming exercise
  is its own task.

## Risks

- **API break for users of `Jido.Memory.Agent.*`.** Out-of-tree
  consumers calling those helpers directly will see compile errors
  after this commit. Per the framework's NO LEGACY ADAPTERS rule
  ([tasks/README.md](README.md)), we don't ship a deprecation
  shim — the migration is documented in
  [task 0042](0042-docs-and-cleanup.md)'s migration guide.
- **Action proliferation.** Eight actions for Memory, three each
  for Identity and Thread — that's fourteen new files. Most are
  five lines each (`run/4` delegates to a pure function in the
  data module), but the file count is real.
- **Persistence interplay.** `Jido.Thread.Slice`'s
  `@behaviour Jido.Persist.Transform` continues to work; the slice
  schema is what `Jido.Persist.thaw/3` validates against on
  restore. Confirm the round-trip in
  `test/jido/persist_test.exs`.
