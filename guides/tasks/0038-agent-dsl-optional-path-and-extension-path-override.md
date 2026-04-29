---
name: Task 0038 — Agent DSL: `path` optional unless `schema` is set; per-extension `path:` override on contributed sections
description: Two related tweaks to the agent DSL surface. (1) Make `path` optional in the `agent do … end` section; required only when `schema` is also set. An agent that's a pure composition root over slices doesn't reserve its own user-domain state, so it doesn't need a path or a schema. The pair `path` + `schema` is the "I have my own slice" signal; either both or neither. (2) Add a built-in `path: :atom` field to every contributed extension section (the schema injected by `Jido.Slice.Extension`'s schema translator from task 0040 — pre-wired here so the contribution mechanism can read it without redefining the field per extension). The host can rename a contributed slice's mount path inline: `memory do path :short_term end`. The default value is the slice's own `path()`. `WalkExtensions` reads the override when building the slice instance.
---

# Task 0038 — Agent DSL: optional `path`, per-extension `path:` override

- Implements: [ADR 0023](../adr/0023-spark-dsl-and-registerable-extensions.md) §2 §4 — agent surface flexibility that pairs with the contribution mechanism in [task 0041](0041-extensions-contribute-dsl-sections.md).
- Depends on: [task 0036](0036-port-action-and-sensor-to-spark.md).
- Blocks: [task 0041](0041-extensions-contribute-dsl-sections.md).
- Leaves tree: **green**.

## Context

The agent DSL today requires both `name` and `path`:

```elixir
@agent_section %Spark.Dsl.Section{
  schema: [
    name: [type: :string, required: true],
    path: [type: :atom, required: true, doc: "Atom slice key …"],
    schema: [type: :any, default: []],
    …
  ]
}
```

A pure composition agent — one whose state is entirely owned by
the slices it mounts — has nothing to put in its own slice. It
shouldn't need a `path` or a `schema`; today it does, with `:domain`
or similar as a stub.

Separately: when a host wants to rename a contributed slice's mount
path (e.g. mount `Jido.Memory.Slice` at `:short_term` instead of the
slice's declared `:memory`), it has to fall through to the legacy
`as:` alias which derives `:memory_short_term` (concatenation, not
override). There's no clean spelling for "use this slice but call
its mount path X."

Both are agent-surface gaps. This task fixes both before [task
0041](0041-extensions-contribute-dsl-sections.md) builds the
contribution mechanism on top.

## Goal

After this commit a path-less agent compiles:

```elixir
defmodule MyApp.OrchestratorAgent do
  use Jido.Agent, extensions: [Jido.AI.ReAct, Jido.Memory.Slice]

  agent do
    name "orchestrator"
    description "Composition over ReAct + Memory."
    # no path, no schema — the agent has no own user-domain slice.
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [MyApp.Actions.LookupOrder]
  end

  memory do
    path :short_term      # rename the slice's :memory mount to :short_term
  end
end
```

Two semantic shifts:

1. **No `path` ⇒ no own slice.** `WalkExtensions` skips seeding a
   slice for the agent's user-domain state when `path` is `nil`.
   The agent's `slice_instances/0` contains only the slices
   contributed via extensions / `default_slices`. The agent's
   `schema/0` returns `[]` (or `nil`), the same way an extension
   without a schema returns `nil` today.
2. **`path` and `schema` are co-required.** If the user sets one,
   they must set the other. A schema with no path has nothing to
   bind to (which key in `agent.state`?); a path with no schema is
   a placeholder that contributes nothing useful. Either both or
   neither — verifier-enforced.

Three semantic shifts on contributed sections:

1. **`path: :atom` is a built-in field on every contributed section.**
   Injected by `Jido.Slice.Extension`'s schema translator (task
   0041) before user fields, so it's always available without the
   slice author opting in. Default is the slice's own `path()`.
2. **`WalkExtensions` reads the override** when building the
   slice instance. The slice's `:memory`-declared `path` becomes
   `:short_term` on this host.
3. **`UniquePaths` verifier already catches collisions.** No
   change there — overriding to a path another extension claims
   raises with the existing error.

## Files to modify

### `lib/jido/dsl/agent.ex`

Drop `required: true` from `path:` in `@agent_section`'s schema.
Update the `doc:` string to reflect the new contract:

```elixir
path: [
  type: :atom,
  doc:
    "Atom slice key where the agent's user-domain state lives. " <>
      "Required when `schema:` is set; omit both for a pure composition agent."
]
```

Same idea for `schema:` if the doc string previously implied it
was always relevant.

### `lib/jido/dsl/agent/verifiers/path_schema_pair.ex` (new)

Add a verifier that enforces "both or neither":

```elixir
defmodule Jido.Dsl.Agent.Verifiers.PathSchemaPair do
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    path = Verifier.get_option(dsl_state, [:agent], :path)
    schema = Verifier.get_option(dsl_state, [:agent], :schema)

    case {path, schema_present?(schema)} do
      {nil, false} -> :ok
      {p, true} when is_atom(p) and p != nil -> :ok
      {nil, true} -> {:error, dsl_error("`schema` is set but `path` is not …")}
      {p, false} when is_atom(p) and p != nil ->
        {:error, dsl_error("`path` is set but `schema` is not …")}
    end
  end

  defp schema_present?(nil), do: false
  defp schema_present?([]), do: false
  defp schema_present?(_), do: true

  defp dsl_error(message) do
    Spark.Error.DslError.exception(message: message, path: [:agent])
  end
end
```

Wire it into `Jido.Dsl.Agent`'s `verifiers:` list.

### `lib/jido/dsl/agent/transformers/walk_extensions.ex`

When the host's `path` is `nil`, do not seed an own-slice entry
into `:slice_instances` / `:slice_paths`. The pseudocode change is
roughly:

```elixir
own_slice =
  case path do
    nil -> nil
    p   -> %SliceInstance{module: nil, path: p, manifest: own_manifest, …}
  end

slice_instances = Enum.reject([own_slice | other_slices], &is_nil/1)
```

(Pseudocode — the real shape depends on what the existing transformer
actually emits for the host's own slice. The point is: skip when
nil.)

Within the same transformer (or a helper), when reading a contributed
section's config, pull a `:path` field if present:

```elixir
section_name = ext_module.__jido_host_section__()
config = Spark.Dsl.Extension.get_opt(dsl_state, [section_name]) || %{}
mount_path = Map.get(config, :path) || ext_module.path()
```

Use `mount_path` as the slice instance's `path`.

### `lib/jido/agent.ex`

The base behaviour module references `path` in places that assume
it's present. Audit `lib/jido/agent.ex` and adjacent runtime code
(`Jido.Agent.State`, `Jido.Agent.Server`, etc.) for code that
unconditionally indexes into `agent.state[path]`. Path-less agents
have no own-slice entry, so this access has to either:

- Skip when `path == nil` (read returns `%{}` or `nil`), or
- Be guarded behind a "this agent has an own slice" check.

The simplest invariant: `agent.path` is `nil` for path-less agents,
and downstream code checks `is_nil(agent.path)` before reading.

### `lib/jido/dsl/slice.ex` — no changes here

The slice's own `path:` stays required. This task is about the
**agent**'s `path:` being optional. A slice always has a path; it's
the slice's job to claim a key in `agent.state`.

### `lib/jido/dsl/agent/route.ex`, `lib/jido/dsl/agent/schedule.ex` — no changes

The host's `signal_routes` and `schedules` sections don't depend on
`path`. Path-less agents can still route and schedule.

## Files to create

- `lib/jido/dsl/agent/verifiers/path_schema_pair.ex` — see above.
- `test/jido/dsl/agent_optional_path_test.exs` — covers:
  - A path-less agent compiles when `extensions:` is empty (corner
    case but valid).
  - A path-less agent with `extensions: [Jido.Memory.Slice]`
    compiles, `slice_instances/0` returns the contributed slice
    only.
  - `path` set, `schema` not set → `CompileError`.
  - `schema` set, `path` not set → `CompileError`.
  - Both set → compiles (existing happy path).
- `test/jido/dsl/extension_path_override_test.exs` — covers:
  - `memory do path :short_term end` mounts `Jido.Memory.Slice` at
    `:short_term`.
  - Path-overridden slice is still routed correctly (its
    `signal_routes` register against the new path).
  - Path collision between two extensions (both override to
    `:foo`) raises `UniquePaths`.
  - Path collision between an extension override and the host's own
    `path:` raises `UniquePaths`.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean.
- `mix test` clean (the FULL suite — no exclusions).
- `mix test --include e2e` clean.
- The two new tests pass; existing agent / DSL tests still pass.
- Spot-check: a tree-grep for `path :domain` (the historical stub
  path used in tests when the agent has no real slice) surfaces
  agents that can drop the line in this commit. Refactor those
  test agents to use the new path-less form for clarity.

## Out of scope

- **Renaming an extension's section name** (e.g. host wants `chat
  do … end` to mean ReAct because the host's domain calls it
  "chat"). This is harder — section names are how Spark dispatches
  the parse tree. v1 doesn't support; deferred to a future task if
  it becomes a real ask.
- **Multi-instance contributed sections** (mounting `Memory.Slice`
  at both `:short_term` and `:long_term`). ADR 0023 already calls
  this out as out-of-scope; needs a list-form section
  (`memories do memory :short … end`). Park.
- **The contribution mechanism itself** (`Jido.Slice.Extension`,
  `extensions: […]` unlocking typed blocks): [task
  0041](0041-extensions-contribute-dsl-sections.md). This task
  prepares the path-override field but doesn't ship the macro that
  injects it; that's where `path:` ends up actually injected into
  every contributed section's schema.

## Risks

- **Existing path-`:domain` stubs.** Many in-tree agents and tests
  set `path :domain` purely because it was required, with no
  matching `schema`. After this task those agents either drop the
  line (preferred) or set both `path` and `schema`. The grep is
  small; sweep it in this commit.
- **Runtime callers that assume an own slice exists.** Anything in
  `Jido.Agent.State` / `Jido.AgentServer` that maps over
  `agent.state[agent.path]` needs the nil-guard. If a regression
  surfaces here, the test suite will catch it; budget time for the
  audit.
- **Default-slices interplay.** A path-less agent with
  `default_slices: false` and no `extensions:` is a "no-op" agent.
  That should still compile (no slices, no schema). Confirm in the
  new test file.
