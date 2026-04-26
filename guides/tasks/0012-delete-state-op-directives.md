# Task 0012 — Delete `Jido.Agent.StateOp` directives; multi-slice via return shape

- Implements: [ADR 0019](../adr/0019-actions-mutate-state-directives-do-side-effects.md) — the cross-cutting cleanup that enforces strict action/directive separation.
- Depends on: [task 0011](0011-tagged-tuple-return-shape.md) (action signature already `{:ok, slice, [directive]}`).
- Blocks: [task 0010](0010-pod-runtime-signal-driven-state-machine.md) (its file-by-file shape assumes `StateOp` is gone and `Pod.Actions.Mutate` is re-pathed).
- Leaves tree: **green**

## Goal

Delete `Jido.Agent.StateOp` (the SetPath / DeletePath / SetState / ReplaceState / DeleteKeys directives) and `Jido.Agent.StateOps` (the apply helper), and re-shape every action that used them. They were a workaround for the deep-merge return semantics from before [task 0002](0002-flatten-agent-state-path-required.md) — once actions returned the *full* new slice, the escape hatch outlived its reason. This task is the long-overdue removal.

After this task:

- `Jido.Agent.StateOp` and `Jido.Agent.StateOps` modules deleted, plus their `defimpl Jido.AgentServer.DirectiveExec` blocks.
- Every action that previously used `StateOp.set_path` / `StateOp.delete_path` for cross-slice writes is **re-pathed** to own the slice it actually mutates (90% of cases) — or returns a `%Jido.Agent.SliceUpdate{slices: %{...}}` map for the genuinely-multi-slice cases.
- The framework's internal `__apply_slice_result__/4` (in `Jido.Agent`) inlines the slice-update step instead of going through `apply_state_ops/2`. The intermediate `%StateOp.SetPath{}` it builds is replaced with a direct `put_in/3`.
- `Pod.Actions.Mutate`, `Pod.BusPlugin.AutoSubscribeChild`, `Pod.BusPlugin.AutoUnsubscribeChild` re-pathed; their actions return slice values directly.

## Files to modify

### `lib/jido/agent.ex`

In `__run_instruction__/3` (the action runner), the slice-result application currently builds a synthetic `StateOp.SetPath` and routes through `StateOps.apply_state_ops/2`:

```elixir
# Before
slice_op = %StateOp.SetPath{path: [slice_path], value: new_slice}
StateOps.apply_state_ops(agent, [slice_op | effects])
```

After: the slice update is one direct `put_in/3` call; the remaining `effects` list contains only side-effect directives:

```elixir
# After
new_state = put_in(agent.state, [slice_path], new_slice)
new_agent = %{agent | state: new_state}
{new_agent, effects}
```

The action's return value position now also accepts `%Jido.Agent.SliceUpdate{slices: %{...}}` for multi-slice writes:

```elixir
defp __apply_slice_result__(agent, _slice_path, %Jido.Agent.SliceUpdate{slices: slices}, effects) do
  new_state =
    Enum.reduce(slices, agent.state, fn {path, value}, acc ->
      put_in(acc, [path], value)
    end)
  {%{agent | state: new_state}, effects}
end

defp __apply_slice_result__(agent, slice_path, new_slice, effects) when is_map(new_slice) do
  new_state = put_in(agent.state, [slice_path], new_slice)
  {%{agent | state: new_state}, effects}
end
```

### `lib/jido/agent/slice_update.ex` *(new file)*

```elixir
defmodule Jido.Agent.SliceUpdate do
  @moduledoc """
  Multi-slice action return value, used when one action transactionally
  mutates multiple slices on the agent.

  Use sparingly — most actions own a single slice and should just return
  the new slice value. Multi-slice writes are an explicit escape hatch
  for genuinely cross-cutting actions.
  """

  @enforce_keys [:slices]
  defstruct [:slices]

  @type t :: %__MODULE__{slices: %{atom() => map()}}
end
```

### `lib/jido/pod/mutable.ex`

The action's StateOp-driven multi-write becomes a single full-slice return. `mutation_effects/3` returns `{:ok, new_pod_slice, [side_effect_directives]}`:

```elixir
@spec mutation_effects(Agent.t(), [Mutation.t() | term()], keyword()) ::
        {:ok, map(), [struct()]} | {:error, term()}
def mutation_effects(%Agent{} = agent, ops, opts \\ []) when is_list(opts) do
  with {:ok, pod_slice} <- TopologyState.fetch_state(agent),
       :ok <- ensure_mutation_idle(pod_slice),
       {:ok, topology} <- TopologyState.fetch_topology(agent),
       {:ok, plan} <- Planner.plan(topology, ops, opts) do
    mutation_state = %{
      id: plan.mutation_id,
      status: :running,
      report: plan.report,
      error: nil
    }

    new_pod_slice = %{pod_slice |
      topology: plan.final_topology,
      topology_version: plan.final_topology.version,
      mutation: mutation_state
    }

    side_effects = [ApplyMutation.new!(plan, Keyword.delete(opts, :mutation_id))]
    {:ok, new_pod_slice, side_effects}
  end
end
```

(Note: `ApplyMutation` still exists at this point — it's deleted in [task 0010](0010-pod-runtime-signal-driven-state-machine.md). Task 0012 only removes `StateOp`.)

### `lib/jido/pod/actions/mutate.ex`

Re-path to `:pod`:

```elixir
use Jido.Action,
  name: "pod_mutate",
  path: :pod,
  schema: [
    ops: [type: {:list, :any}, required: true],
    opts: [type: :map, default: %{}]
  ]

def run(%Jido.Signal{id: signal_id, data: %{ops: ops, opts: opts}}, _slice, _opts, ctx) do
  effect_opts = Keyword.put(Map.to_list(opts || %{}), :mutation_id, signal_id)
  Pod.mutation_effects(ctx.agent, ops, effect_opts)
end
```

The action's return value is now `{:ok, new_pod_slice, [side_effects]}` — the framework writes `agent.state.pod = new_pod_slice` per the action's `path: :pod`. The previous incidental `:app` slice scribble (`%{mutation_queued: true, mutation_id: signal_id}`) was never read by anyone and is dropped.

### `lib/jido/pod/bus_plugin/auto_subscribe_child.ex`

Re-path to `:pod_bus`. Drop the `StateOp.SetPath` directive; return the new slice with the subscription added.

```elixir
use Jido.Action,
  name: "pod_auto_subscribe_child",
  path: :pod_bus,
  schema: [...]

def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
  with {:ok, bus} <- fetch_bus(slice),  # slice IS the :pod_bus slice now
       {:ok, routes} <- fetch_routes(params.child_module) do
    sub_ids = subscribe_to_routes(bus, routes, params)
    new_slice = put_in(slice, [:subscriptions, params.tag], sub_ids)
    {:ok, new_slice, []}
  else
    {:error, reason} ->
      Logger.warning("pod_bus: skipped auto-subscribe — #{reason}")
      {:ok, slice, []}
  end
end
```

The `fetch_bus` helper that previously read from `agent_state` (the full agent state) needs adjustment to read from the `:pod_bus` slice directly — the bus pid lives in that slice already.

### `lib/jido/pod/bus_plugin/auto_unsubscribe_child.ex`

Same shape: re-path to `:pod_bus`, drop the `StateOp.DeletePath` directive, return the slice with the subscription key removed:

```elixir
def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
  with {:ok, bus} <- fetch_bus(slice),
       sub_ids when is_list(sub_ids) <- get_in(slice, [:subscriptions, params.tag]) do
    unsubscribe_each(bus, sub_ids)
    new_slice = update_in(slice, [:subscriptions], &Map.delete(&1, params.tag))
    {:ok, new_slice, []}
  else
    _ -> {:ok, slice, []}
  end
end
```

### `test/support/test_actions.ex`

Audit the test action helpers. Any that returned `[%StateOp.SetPath{...}]` must rewrite — either re-path the test action or have it return the slice value with the desired keys set. Most test actions are single-slice; a handful might need `%SliceUpdate{}`.

### `test/examples/basics/state_ops_test.exs`

This file documents the StateOp API as a public-facing example. **Delete it** — `StateOp` is no longer public surface. If a documentation example is needed for "how do I update agent state from an action," write a new short example under `test/examples/basics/` showing `path: + slice return + multi-slice via SliceUpdate`. (Optional, separate scope.)

### `test/jido/agent/state_op_test.exs` and `test/jido/agent/state_ops_test.exs`

**Delete both.** They cover the StateOp module and the apply helper, both of which go away.

### `test/jido/agent_plugin_integration_test.exs`

Audit and rewrite any callsites. Plugin integrations that used `StateOp.set_path` to bridge slices should re-path to the slice they're mutating.

### `test/jido/agent/agent_test.exs`

Same audit. Most uses are likely either internal-API exercise (delete) or examples of action behavior (rewrite to slice return).

### `test/jido/pod/mutation_runtime_test.exs`

The `StuckMutationAction` shim added in task 0009 forges the slice via `StateOp.set_path([:pod, :mutation], ...)`. After this task, rewrite as:

```elixir
defmodule StuckMutationAction do
  use Jido.Action, name: "stuck_mutation", path: :pod, schema: []

  def run(_signal, slice, _opts, _ctx) do
    new_slice = %{slice |
      mutation: %{id: "stuck-id", status: :running, report: nil, error: nil}
    }
    {:ok, new_slice, []}
  end
end
```

Same effect, no `StateOp`. (This shim is then deleted entirely in task 0010 once concurrent rejection is naturally testable.)

## Files to create

- `lib/jido/agent/slice_update.ex` — multi-slice return shape

## Files to delete

- `lib/jido/agent/state_op.ex` (the module + the 5 directive structs)
- `lib/jido/agent/state_ops.ex` (the apply helper)
- The `defimpl Jido.AgentServer.DirectiveExec, for: Jido.Agent.StateOp.<X>` blocks (5 of them, in whichever file they live)
- `test/jido/agent/state_op_test.exs`
- `test/jido/agent/state_ops_test.exs`
- `test/examples/basics/state_ops_test.exs` (replace with a short slice-return example or just delete)

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix test` — full suite passes.
- `grep -rn "StateOp" lib/ test/` returns no hits (other than this task doc + ADR 0019 / commit messages).
- The new `%Jido.Agent.SliceUpdate{}` shape is exercised by at least one test (a multi-slice action that touches two slices in one return).
- `Pod.Actions.Mutate` declares `path: :pod` and returns the new pod slice value directly.
- `Pod.BusPlugin.AutoSubscribeChild` and `AutoUnsubscribeChild` declare `path: :pod_bus` and return slice values directly.
- `mix docs` builds without warnings about deleted modules.

## Out of scope

- **Pod runtime state machine** — task 0010. This task is purely API-shape cleanup; the pod's mutation execution stays synchronous (per task 0009's Phase 1 contract) until task 0010 lands.
- **`Jido.Agent.StateOps.apply_state_ops/2` callsites outside the framework** — there are none in-repo. If an external project depends on it, they break. Per the [tasks NO-LEGACY-ADAPTERS rule](README.md), no shim.
- **A multi-slice declaration syntax** like `path: [:pod, :pod_bus]`. The `%SliceUpdate{}` return shape is the explicit mechanism; declaring multi-slice in `path:` would make `__resolve_slice_path__` ambiguous. Stays single-valued.

## Risks

- **`Pod.BusPlugin` re-path may surface assumptions about agent_state shape.** The action's slice argument changes from "the full agent state" to "the `:pod_bus` slice." The `fetch_bus/1` helper and any other helpers that were threading the full agent state need to be updated to thread the slice instead. This is a small refactor inside the bus plugin actions but worth scanning for surprises.

- **`%SliceUpdate{}` multi-slice writes don't have transactional guarantees across slices today.** If `put_in` for slice A succeeds but the second `put_in` for slice B raises (impossibly small risk for pure map updates, but conceptually), state is partially mutated. Document the assumption: maps don't fail to update; multi-slice atomicity holds. If a future case needs harder guarantees (e.g. validation between slices), add it then.

- **Test coverage gaps.** Deleting `state_op_test.exs` and `state_ops_test.exs` removes coverage of the modules they test — but the modules themselves are gone, so the coverage is moot. Make sure the rewritten tests in `mutation_runtime_test.exs` and the test action audits cover the new shapes equivalently.

- **Doctest examples.** Any module docstring that uses `StateOp.set_path` as an example needs updating. Audit by `grep -rn "StateOp" lib/` and rewrite the docstring examples to use the slice-return shape.

- **Migration guide.** External users of the framework who learned the StateOp pattern from old docs will find it gone. Add a section to the migration guide (if one exists) covering "StateOp directives → return your slice + use `%SliceUpdate{}` for cross-slice." Otherwise note in the commit message and CHANGELOG.

- **Implementation order matters with task 0010.** Task 0010's design assumes `StateOp` is already gone (its file-by-file shows the new `mutation_effects` returning `{:ok, slice, [...]}` directly with no StateOp). Land 0012 first, then 0010. If 0010 ships first, the `StuckMutationAction` shim has nowhere to go (no `StateOp` to forge slice) AND the `MutateProgress` action's `path: :pod` declaration won't compile until `Pod.Actions.Mutate` is also re-pathed and its slice-update mechanism cleaned up.
