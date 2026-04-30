---
name: Task 0062 — Multi-instance slice mounts fan out at signal-route dispatch
description: After task 0053 the agent's `slices do slice :path, Module end` block lets the same slice module mount at multiple paths (e.g. `slice :slack_support, SlackPlugin; slice :slack_sales, SlackPlugin`). What the new DSL does NOT yet do is fan signal dispatch out across those mounts — the slice's `signal_routes` are absolute, both mounts contribute identical `(signal_type, action)` pairs to the agent's combined route table, and `NoRouteConflicts` raises at compile time. Per the design intent: when multiple slices subscribe to the same signal type, the framework should call the action **once per matching slice instance** with each instance's slice value, accumulate the per-slice return values, and fan responses out symmetrically. This task implements that semantics.
---

# Task 0062 — Multi-instance slice mounts fan out at signal-route dispatch

- Depends on: [task 0053](0053-slices-as-agent-dsl-entity.md) (the `slices do slice :path, Module end` mount entity is the unit of fan-out).
- Blocks: nothing — the framework currently rejects multi-instance mounts at compile time, so users haven't built on the missing capability. Recommended sequencing: lands directly after task 0053 alongside [task 0061](0061-collapse-pod-into-agent-extension.md); independent of the rename chain (0044–0050).
- Leaves tree: **green**.

## Problem

Today's `Jido.Dsl.Agent.Verifiers.NoRouteConflicts` is a flat
"every (signal_type, action, priority) tuple must be unique"
check. That rule was correct under the pre-task-0053 DSL, where each
plugin mounted at exactly one path and its `signal_routes` keyed
the dispatch table 1:1. After task 0053 the same slice module can
mount multiple times:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent

  slices do
    slice :slack_support, MyApp.SlackPlugin
    slice :slack_sales,   MyApp.SlackPlugin
  end
end
```

Both mounts contribute the slice's `signal_routes`:

```elixir
# In MyApp.SlackPlugin:
signal_routes do
  route "slack.send", MyApp.SlackActions.Send
end
```

`Jido.Plugin.Instance.derive_route_prefix/2` prefixes each route with
the plugin's *name* (not its mount path), so both mounts produce
`"slack.slack.send"` → `MyApp.SlackActions.Send` and
`NoRouteConflicts` raises:

```
** (Spark.Error.DslError) signal_routes :
   Route conflicts detected:
   - Route conflict: 'slack.slack.send' defined multiple times with same priority -10
     (targets: MyApp.SlackActions.Send, MyApp.SlackActions.Send)
```

Conceptually the configuration is fine — the user wants two independent
Slack mounts at different paths. The framework just has no concept of
"this signal targets multiple slices in parallel; run the action once
per slice with its own state." The right semantics:

1. The signal arrives.
2. The router finds every route that matches the signal's type.
3. For each matching route, the framework calls
   `action.run(signal, agent.state[mount_path], opts, ctx)` —
   *once per mount that owns this route*, each call seeing only its
   own slice's state.
4. Each call returns `{:ok, new_slice, [directives]}` for ITS slice.
   The framework merges the per-mount slice updates into `agent.state`
   and aggregates directives.
5. Ack semantics: the request/response pair carries the aggregate of
   per-mount return values (or an error if any mount errored).

The mental model is "each slice mount is an independent subscriber to
the signal" — same as a multi-tenant pub/sub system would do.

## Target shape

### Compile-time route table

Today `:expanded_plugin_routes` and `:expanded_slice_routes` are flat
lists of `{signal_type, action, opts}` tuples (or
`{signal_type, match_fn, action, opts}` when a match function is
present). After this task, each route entry carries the mount path of
the slice that contributed it:

```elixir
%Jido.Agent.Route{
  signal_type: "slack.slack.send",
  action: MyApp.SlackActions.Send,
  mount_path: :slack_support,        # <-- new
  priority: -10,
  match: nil,
  static: nil
}
```

`Jido.Dsl.Agent.Info.plugin_routes/1` returns the same shape so callers
can see which mount each route originated from.

### `NoRouteConflicts` rule update

Conflict iff: same `(signal_type, action, priority, mount_path)`
quadruple appears more than once. Same `(signal_type, action,
priority)` triple at *different* mount paths is **not** a conflict —
that's the fan-out case.

User-host-declared `signal_routes do … end` entries on the agent
itself live at no mount path (the agent owns them); they conflict only
with other agent-level routes at the same `(signal_type, priority)`.

### Runtime fan-out at `cmd/2`

`Jido.Dsl.Agent.Transformers.GenerateAccessors` emits
`__resolve_slice_path__/1` today returning a single atom. The
fan-out version returns a list of `{action_module, mount_path}` pairs
the dispatch loop iterates over:

```elixir
defp __dispatch_routes__(action) when is_atom(action) do
  case Map.get(@slice_path_for_action, action) do
    [] ->
      # No slice owns this action; fall through to the action's escape
      # valve or the agent's own path.
      [{action, escape_valve_or_agent_path(action)}]

    paths when is_list(paths) ->
      Enum.map(paths, &{action, &1})
  end
end
```

`__run_instruction__/2` becomes a fold over the dispatch list:

```elixir
defp __run_instruction__(agent, %Instruction{action: action} = instruction, jido_instance) do
  dispatch_list = __dispatch_routes__(action)

  Enum.reduce_while(dispatch_list, {:ok, agent, []}, fn
    {action_mod, mount_path}, {:ok, acc_agent, acc_dirs} ->
      scoped_state = Map.get(acc_agent.state, mount_path, %{})
      scoped_instruction = put_scoped_context(instruction, scoped_state, acc_agent)

      case Jido.Exec.run(scoped_instruction) do
        {:ok, new_slice, effects} when is_map(new_slice) ->
          {new_agent, dirs} =
            __apply_slice_result__(acc_agent, mount_path, new_slice, List.wrap(effects))

          {:cont, {:ok, new_agent, acc_dirs ++ dirs}}

        {:error, reason} ->
          {:halt, {:error, Jido.Error.from_term(reason)}}
      end
  end)
end
```

The agent's own slice and the action's `path :foo` escape valve still
work — they're just one mount path (the agent's own) instead of many.

### Signal router fan-out

The `agent_server` signal pipeline already routes a signal through the
`:expanded_signal_routes` table to find matching action targets. Each
match → one `cmd/2` invocation. After this task the router emits one
`Instruction` per matching mount; the cmd loop writes each result to
its mount path. Net effect: a single inbound signal can update every
mounted instance of a multi-mount slice in one turn.

### Per-mount config visibility

Each slice mount has its own `options` map (`slice :slack_support,
SlackPlugin, options: [token: "support-token"]`). At runtime, the
action's `ctx` should expose the *mount's* config so the action knows
which workspace/tenant/instance it's serving:

```elixir
def run(signal, slice, _opts, ctx) do
  token = ctx.slice_config[:token]   # whichever mount is being dispatched
  # → "support-token" or "sales-token" depending on which mount fired
  ...
end
```

Today `ctx` already carries `:agent` and `:state`; add `:slice_config`
and `:slice_path` so multi-instance actions can self-identify.

## What moves where

| Today | Target |
|---|---|
| `:slice_path_for_action` is `%{action_module => atom_path}` | `:slice_path_for_action` is `%{action_module => [atom_path, …]}`. Single-mount cases keep working (one-element list); multi-mount cases get the fan-out. |
| `__resolve_slice_path__/1` returns a single atom | `__dispatch_routes__/1` returns a list of `{action, mount_path}` pairs. Caller iterates. |
| `__run_instruction__` → `__apply_slice_result__` once | Fold over the dispatch list; each pair updates its own mount path. |
| `NoRouteConflicts` rejects same `(signal, action, priority)` regardless of mount | Rejects only when the *same mount path* contributes the same triple twice; cross-mount duplicates are allowed. |
| `Jido.Plugin.Routes.detect_conflicts/1` uses `(path, target, priority)` as the conflict key | Conflict key becomes `(path, target, priority, mount_path)`. |
| `expand_routes` returns `[{signal, action, opts}]` | Returns `[%Jido.Agent.Route{}]` records that carry `mount_path`. |
| `ctx` in action callbacks carries `:state, :ctx, :agent, :agent_server_pid` | Adds `:slice_path` and `:slice_config` so multi-mount actions can self-identify. |

## Edge cases

1. **Action declared on agent's own `signal_routes`**, not in any
   slice's routes. `:slice_path_for_action` returns `[]`; the
   resolver falls through to the action's `path :foo` escape valve or
   the agent's own path. Same as today; no fan-out involved.

2. **Same action used by both a slice and the agent's own
   `signal_routes`**. Edge case — fan out across the slice mounts AND
   include the agent-level route. Probably the right behaviour, but
   worth a unit test that locks it in.

3. **Mount config differing between instances** (e.g. SlackPlugin
   `:slack_support` vs `:slack_sales`). The action gets `ctx.slice_config`
   per-mount so it can pick the right token / workspace / etc. Tests
   should cover the case where two mounts run the same action with
   different config and produce different side effects.

4. **One mount errors, another succeeds**. The fold halts on the first
   `{:error, _}` from any mount. Per ADR 0019 / task 0011 (tagged-tuple
   return shape) the prior mounts' state mutations vanish (cmd is
   atomic). Document this — the user might assume per-mount isolation.

5. **Default slices vs user mounts** — default slices and user mounts
   both flow through the same fan-out path. No special case.

## Acceptance

- `git grep -nE 'NoRouteConflicts.verify' lib/` returns the verifier
  with the new "key by mount path" logic; cross-mount duplicates of the
  same `(signal, action, priority)` triple are not flagged.
- A test fixture `MultiSlackAgent` with `slice :slack_support, SlackPlugin;
  slice :slack_sales, SlackPlugin` compiles cleanly.
- A signal `"slack.slack.send"` dispatched to that agent fires
  `SlackPlugin`'s `Send` action **twice** — once with
  `agent.state.slack_support` and `ctx.slice_config[:token] ==
  "support-token"`, once with `agent.state.slack_sales` and
  `ctx.slice_config[:token] == "sales-token"`. After the cmd
  completes, both slice maps are updated.
- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix test --include e2e` clean.
- The `# NOTE: revisit per task 0053 — multi-instance via as: …`
  TODO markers I left scattered through the test suite (and the
  pre-task-0053 deletions in
  test/jido/agent_plugin_integration_test.exs) get back-filled with
  rewritten tests that exercise the fan-out shape.
- `documentation/dsls/DSL-Jido.Agent.md` regenerated and the
  `slices do …` section's docs explicitly call out multi-instance
  mounting + fan-out semantics.

## Out of scope

- Per-mount route *prefixing* (`route_prefix: "support"` on
  `slice :slack_support, SlackPlugin, route_prefix: "support"`) so
  `"slack.send"` becomes `"support.slack.send"` per mount. That's a
  *different* multi-instance pattern (route addresses are unique per
  mount; no fan-out needed) and conflicts with the fan-out semantics
  this task implements. Pick one. This task picks fan-out. If
  per-mount prefixing turns out to be useful too, it's its own
  follow-up.
- Aggregating ack/response payloads across mounts. Today an action
  returns `{:ok, new_slice, [directives]}` and the cmd loop hands
  back the directives. Under fan-out the directive list is the
  concatenation of per-mount directives. Whether the ack should
  carry a per-mount summary (`%{slack_support: ack1, slack_sales:
  ack2}`) vs the concatenated stream is a downstream design call —
  start with concatenation; revisit if users ask for per-mount.
- Renaming `Jido.Plugin.Instance.derive_route_prefix/2` (which still
  uses the plugin's name + `as:` alias). The `as:` field is dead
  code after task 0053 but it's referenced through enough places
  that a rename + cleanup is its own task. After this task the field
  is unused for fan-out; can stay quietly dead until cleanup.

## Risks

- **Single inbound signal mutating multiple slice paths in one cmd
  turn** changes the atomicity story. Today `__run_instruction__`
  produces one slice update; after fan-out it produces N. The
  reduce-while contract still gives all-or-nothing — but the surface
  area for a partial-failure bug grows. Test coverage needs to lock
  in: "first mount fails, all prior mount mutations roll back."
- **`ctx.slice_config` leaks per-mount config to action authors.**
  That's intentional but it's a new surface. Slice-config
  validation already happens at mount time via Zoi; the runtime
  passthrough is just a Map.get. Document the contract.
- **Routes table gets bigger**. With N mounts of the same slice, the
  agent's `:expanded_plugin_routes` is N× longer than today. Should
  be fine for typical N (1–10) but worth a sanity check on a worst
  case (e.g. 100 mounts of the same plugin) before this lands.
- **Reverse-compatibility surface**. Existing single-mount agents
  see no behaviour change — fan-out over a one-element list is
  identical to today's path. The risk concentrates on agents that
  intentionally relied on `NoRouteConflicts` to catch
  misconfiguration. The verifier still flags *same-mount* duplicate
  routes; only the cross-mount case is relaxed.
