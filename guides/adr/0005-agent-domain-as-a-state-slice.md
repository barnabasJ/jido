# 0005. Agent domain state is a first-class `state_key` slice

- Status: Accepted
- Date: 2026-04-21
- Related ADRs: [0003](0003-server-state-access-lives-in-directives.md)
- Related commits: TBD

## Context

`agent.state` is a shared namespace. Plugins carve out named slices via
`use Jido.Plugin, state_key: :__pod__` (or `:__bus_wiring__`,
`:__memory__`, ...). The runtime seeds each plugin's schema defaults
under that key at mount time and the plugin's state stays isolated
from everything else.

The user's own domain state — the fields declared in `use Jido.Agent,
schema: [count: [...], last_reserved: [...]]` — lives **at the top
level of `agent.state`**, not under a named key. That creates an
asymmetry:

```
agent.state = %{
  count:          0,           # user domain, flat at the top
  last_reserved:  nil,         # user domain, flat at the top
  __pod__:        %{...},      # Pod.Plugin's slice
  __bus_wiring__: %{...},      # BusPlugin's slice
  __parent__:     %ParentRef{} # runtime metadata
}
```

Two consequences:

1. **Actions see the whole bag.** `ctx.state = agent.state`, including
   plugin slices and runtime refs. The action should only care about
   user-domain fields but the rest is right there, inviting wrong
   reads.
2. **Deep-merge return is the only way to update.** An action
   returning `{:ok, %{count: 5}}` gets deep-merged into the whole
   state. Merge can add and overwrite but cannot delete or replace a
   sub-map wholesale — for those the author drops down to explicit
   `%StateOp.DeletePath{}` / `%ReplaceState{}` / `%SetPath{}`
   directives.

The ELM/Redux shape — `(slice, msg) -> new_slice` — is not available
for actions the way it already is for plugins, which know exactly which
slice they own.

## Decision

Promote agent domain state to a first-class slice under the same
`state_key:` mechanism plugins already use. A new
`Jido.Agent.ScopedAction` macro lets actions declare which slice they
own, and the runtime maps their return to a targeted state-op.

### 1. Agent declares its slice

```elixir
defmodule Counter do
  use Jido.Agent,
    name: "counter",
    state_key: :__domain__,
    schema: [count: [type: :integer, default: 0]]
end
```

At `Counter.new/1`, schema defaults are seeded under
`agent.state[:__domain__]` instead of at the top level. `agent.state`
now looks the way a combined-reducers tree does:

```
agent.state = %{
  __domain__:     %{count: 0, ...},        # agent's own slice
  __pod__:        %{...},                  # Pod.Plugin (unchanged)
  __bus_wiring__: %{...},                  # BusPlugin (unchanged)
  __parent__:     %ParentRef{}             # runtime metadata (unchanged)
}
```

If `state_key:` is omitted on `use Jido.Agent` the legacy top-level
layout is preserved. Migration is opt-in per agent.

### 2. Actions declare the slice they operate on

```elixir
defmodule Increment do
  use Jido.Agent.ScopedAction,
    name: "increment",
    state_key: :__domain__,
    schema: [by: [type: :integer, default: 1]]

  @impl true
  def run(%{by: by}, %{state: state}) do
    # state is JUST the :__domain__ slice, not the whole agent.state.
    # Runtime extracted it before calling; no plugin slices visible.
    {:ok, %{state | count: state.count + by}}
    # Return is treated as a whole-slice replacement, not a diff merge.
  end
end
```

`Jido.Agent.ScopedAction` is a thin wrapper over `Jido.Action`:

```elixir
defmodule Jido.Agent.ScopedAction do
  defmacro __using__(opts) do
    {state_key, action_opts} = Keyword.pop!(opts, :state_key)

    quote do
      use Jido.Action, unquote(action_opts)

      @state_key unquote(state_key)
      def state_key, do: @state_key
    end
  end
end
```

Requiring `state_key:` at the macro level is deliberate — a scoped
action without a slice is a contradiction.

### 3. Runtime does the combine-reducers dance

`Jido.Agent.Strategy.Direct.run_instruction/3` is the one touchpoint.
Before invoking the action:

* If the action module exports `state_key/0`, extract
  `agent.state[state_key]` and pass that as `ctx.state`. The rest of
  `agent.state` is invisible to the action.

After the action returns, interpret the result relative to scope:

| Result | Semantics when `state_key` set | Semantics when `state_key` unset (legacy) |
|---|---|---|
| `{:ok, map}` | whole-slice replace via `%SetPath{path: [state_key], value: map}` | deep-merge into `agent.state` |
| `{:ok, map, [directives]}` | same, plus the directive list | same, plus the directive list |
| `{:error, reason}` | unchanged | unchanged |

Explicit state-op directives emitted by scoped actions keep full-state
semantics. A scoped action that wants to touch its own slice at a
nested path still writes `%SetPath{path: [:__domain__, :cart, :items],
value: ...}` — scoping is a convenience for the common case, not a
relative-path model. That keeps one coordinate system for directives.

### 4. Deletions are trivial inside scoped actions

```elixir
{:ok, Map.delete(state, :last_reserved)}
```

The runtime replaces the slice wholesale, so the key vanishes. No
`%DeletePath{}` needed for the common user-domain case. The state-op
directives stay around for plugin state and cross-slice work.

## Consequences

- **Elm shape is available.** Scoped actions get `(slice, msg) ->
  new_slice` — a pure reducer over their owned slice. Plugin state is
  preserved by construction (the runtime never lets the action touch
  keys outside its slice).
- **Symmetry with plugins.** One keyword (`state_key:`), one concept,
  three call sites: plugin, agent, scoped action. "Who owns this
  slice?" has a consistent answer.
- **Legacy-compatible.** Agents without `state_key:` keep the current
  flat layout. Existing actions without `use Jido.Agent.ScopedAction`
  keep deep-merge semantics. Nothing in the ecosystem breaks until an
  author opts in.
- **Struct fields stay.** `use Jido.Agent` still generates struct
  fields from `schema:` (so `%Counter{}` still has `:count`). The
  authoritative state lives under `agent.state[state_key]` when
  scoped; the struct field is initialised from the schema default and
  not re-synced after mutations. This matches how plugin state works
  today — Zoi schemas are for init, `agent.state` is for live values.
- **Same directive vocabulary.** `%SetPath{}`, `%DeletePath{}`,
  `%ReplaceState{}` continue to operate on the full `agent.state`.
  Scoped actions that stay in their lane get the short form; anything
  cross-cutting is explicit.

## Alternatives considered

- **Mandatory scoping — break the top-level layout.** Forces every
  agent to carry a slice key and every action to declare one. Cleaner
  long-term but a breaking change we don't need right now; opt-in
  with `state_key:` on the agent gives the same shape without
  disrupting existing code.
- **Per-action scoping without an agent-level declaration.** A scoped
  action could target any slice key and the agent itself would not
  need to know. Technically works but breaks the symmetry with
  plugins (plugins declare their slice at mount time; agents declare
  via `use`). We want the agent to participate in the combined-reducer
  shape the same way plugins do.
- **A `view:` keyword instead of `state_key:`.** Suggests a read-only
  projection; scoped actions are read-and-replace. Rejected in
  favour of the existing keyword.
- **Expose a relative-path state-op directive.** Scoped actions could
  emit `%SetPath{path: [:cart, :items], value: ...}` interpreted
  against their slice. Adds a second coordinate system; rejected in
  favour of "scoping is for the `{:ok, slice}` shorthand, not for
  explicit state ops."

## Migration

1. Write an agent with `state_key: :__domain__` and
   `use Jido.Agent.ScopedAction` actions.
2. Confirm existing actions/agents are unchanged.
3. Eventually: deprecate top-level layout, set `state_key:` default
   to `:__domain__`, ship a `mix jido.migrate.state_key` scaffold that
   rewrites `use Jido.Agent` and moves schema-backed fields into the
   slice. Not part of this ADR; a future one when we're ready to make
   the flat layout the minority case.
