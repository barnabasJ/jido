# 0025-amendment. Slices as a first-class agent DSL entity

- Status: Accepted
- Date: 2026-04-30
- Amends: [ADR 0025](0025-extension-directory-layout.md), [ADR 0023](0023-spark-dsl-and-registerable-extensions.md) §3
- Implements: [Task 0053](../tasks/0053-slices-as-agent-dsl-entity.md)

## Context

Before this amendment, a `Jido.Agent` enumerated its slices, plugins,
and middleware via a single ordered `extensions: […]` keyword list on
`use Jido.Agent`. The compile-time `WalkExtensions` transformer
classified each entry by Spark marker (`Spark.Dsl.is?(mod, Jido.Plugin)`,
`Spark.Dsl.is?(mod, Jido.Slice)`, `@behaviour Jido.Middleware`).

Two problems followed:

1. **Slices owned their mount path.** A slice module declared
   `path :memory` on its own DSL; the agent silently inherited that
   path. This conflated "what the slice is" with "where on this agent
   it lives." The same slice could not mount at different paths on
   different agents, and every action under that slice redundantly
   declared `path :memory` to flow back to the right slot.

2. **`__resolve_slice_path__/1` only consulted the action.** The
   compile-time route from action result → slice key was per-action:
   either the action declared `path :foo` itself, or the framework
   fell back to the agent's own path. There was no agent-level
   lookup of "this action belongs to slice X." An agent could not
   route a re-used action to one slice on agent A and a different
   slice on agent B.

## Decision

Lift slice/plugin enumeration into a **typed DSL section on the
agent**:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent, middleware: [MyApp.AuthMiddleware, Jido.Plugin.FSM]

  agent do
    name "support"
    path :domain
    schema [counter: [type: :integer, default: 0]]
  end

  slices do
    slice :memory,   Jido.Memory.Slice
    slice :identity, Jido.Identity.Slice
    slice :fsm, Jido.Plugin.FSM, options: [states: [:idle, :working]]
  end
end
```

The `slices do … end` block is the **single source of truth** for
path-to-slice binding on this agent. Each `slice :path, Module` line
mounts a slice or plugin at the agent-declared `:path`.

### `extensions: […]` is now scoped

`extensions: […]` keeps its role for **typed DSL contributions** only
(the `Jido.Slice.Extension` host-section mechanism, e.g.
`Jido.AI.ReAct` to unlock `react do … end`). It is no longer the
channel for slice/plugin enumeration.

### `middleware:` is a top-level opt

Middleware ordering matters (it determines the wrap-chain order), so
middleware lives in a flat ordered top-level list:

```elixir
use Jido.Agent, middleware: [MyApp.Auth, Jido.Plugin.FSM, MyApp.Logging]
```

Plugins with middleware behaviour appear in **both** `slices do …`
(for their slice half — path/options) **and** `middleware: […]` (for
ordering of their middleware half).

### Resolution mechanism: signal-route ownership

`__resolve_slice_path__/1` now consults a compile-time lookup table
`%{action_module => mount_path}` built by walking each mounted slice's
`signal_routes/0` table. The slice that routes to a given action is
the slice that owns the action's return value.

```elixir
%{
  Jido.Memory.Actions.Ensure        => :memory,
  Jido.Memory.Actions.PutInSpace    => :memory,
  Jido.Identity.Actions.Ensure      => :identity,
  Jido.Plugin.FSM.Transition        => :fsm,
  ...
}
```

Resolution order at `cmd/2` time:

1. Lookup the action in the slice mount table → return that slice's
   mount path.
2. Fall back to the agent's own `path :foo` (the agent's domain
   slice).

`Jido.Dsl.Action` no longer carries a `path:` field. Action modules
are completely decoupled from agent state shape — the same action
module can be routed to one slice on agent A and a different slice on
agent B by virtue of which slice's `signal_routes` references it.

### Slice DSL keeps `path :foo` as an optional fallback

Slices and plugins may **optionally** declare a `path :foo` in their
own `slice do …` DSL. This is consulted only by:

1. **Default slices.** The framework's package defaults
   (`Jido.Memory.Slice`, `Jido.Identity.Slice`, `Jido.Thread.Slice`)
   ship with explicit `{path, module}` tuples in `Jido.Agent.DefaultSlices.package_defaults/0`,
   so the path travels alongside the module. The slice's own
   `path :foo` declaration is informational fallback.
2. **Pod plugin auto-attachment.** `Jido.Pod.Plugin` mounts at `:pod`
   via `AttachPodPlugin` transformer. The hardcoded `:pod` path is
   the source of truth; the slice's declared `path :foo` is a
   readability aid.

The agent's `slices do slice :path, Module end` mount path **always
wins**. Most user-defined slices should omit `path :foo` entirely
and let the agent assign it.

## Alternatives considered

- **Namespace-prefix match.** Build the lookup table by walking each
  mounted slice's submodule namespace (`Jido.Memory.Actions.*` →
  `:memory`). Cheap, but brittle if a user's action module lives
  outside the slice's namespace.
- **Explicit `belongs_to_slice :foo` on each action.** Per-action
  pointer at the slice it belongs to. Most explicit, but every action
  ends up declaring the same metadata its parent slice already
  enumerates.
- **Drop `path :foo` from `Jido.Dsl.Slice` entirely.** The cleanest
  shape — slices have *no* opinion on their mount path. Rejected for
  this iteration: Pod's `AttachPodPlugin` and the package-default
  list both want a single source of truth for "this slice mounts at
  `:pod` / `:memory` / `:identity` / `:thread` by convention,"
  and stripping the field forces every default-slice spec into a
  per-call path declaration. The compromise — keep the field
  optional, document that the agent's `slices do …` always wins,
  most user slices should omit it — preserves the property the
  spec wanted (path is per-mount) while leaving the framework's
  default-attachment plumbing alone.

## Consequences

- **Same slice mounts at different paths on different agents.**
  `slice :short_term, Jido.Memory.Slice` on one agent; `slice :long_term,
  Jido.Memory.Slice` on another.
- **Actions never declare path.** `Jido.Dsl.Action` schema drops
  the `path:` field. Eight memory actions, three identity actions,
  three thread actions, two pod actions, two bus-plugin actions, and
  one FSM transition action all delete their redundant `path :foo`
  line.
- **Plugin / slice / middleware classification at the agent boundary
  becomes deterministic.** No more `:as => :plugin` / `:as => :slice`
  override hacks: the `slices do …` block always means slice/plugin,
  and `middleware: […]` always means middleware. The classification
  ambiguity in the old `extensions: [...]` walker disappears.
- **`extensions: […]` retains its role** for opening typed DSL
  contributions (`react do …`, future `memory do …` etc.). The
  registration semantics (the `__shadow_extensions__/2` macro
  hook) are unchanged.
- **`Jido.Agent.DefaultSlices.package_defaults/0` returns a list of
  `{path, module}` tuples.** Format change for the default-slice
  spec; the override surface (`default_slices: %{path => false |
  Module | {Module, config}}`) is unchanged.

## Migration

Per the task spec — no shims, no transitional adapters. Every callsite
rewrites to the new shape in the same commit.
