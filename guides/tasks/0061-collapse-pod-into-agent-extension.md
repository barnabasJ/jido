---
name: Task 0061 — Collapse `Jido.Pod` into a `Jido.Slice` + `Jido.Slice.Extension`
description: A pod is structurally a slice mounted at `:pod` plus a typed `pod do topology … end` host section — exactly the shape `Jido.AI.ReAct` already uses (`use Jido.Slice` + `use Jido.Slice.Extension, host_section: :react`). Today `Jido.Pod` predates the slice-extension mechanism and is modeled as a sibling of `Jido.Agent` (its own `use Spark.Dsl`, its own `__using__`, its own `handle_opts`, its own opt_schema with duplicated `extensions:` / `middleware:` / `jido:` / `default_slices:` keys). Collapse Pod into the slice-extension shape so users write `use Jido.Agent, extensions: [Jido.Pod]` and the `pod do topology … end` block opens automatically. Delete `Jido.Dsl.Pod`, `Jido.Pod.BeforeCompile`, `Jido.Pod.Transformers.AttachPodPlugin`, `Jido.Pod.Transformers.ResolveTopology`, the `defmacro __using__` on `Jido.Pod`, and the duplicated opt_schema entries.
---

# Task 0061 — Collapse `Jido.Pod` into a `Jido.Slice` + `Jido.Slice.Extension`

- Depends on: [task 0053](0053-slices-as-agent-dsl-entity.md) (the agent DSL must already have a first-class `slices do … end` entity so the pod plugin can mount through it instead of through a Pod-specific transformer).
- Blocks: nothing in the rename chain (0044–0050 don't touch `Jido.Pod`'s shape) or the dashboard chain (0054–0060). Recommended sequencing: lands directly after 0053, before 0044 starts.
- Leaves tree: **green**.

## Problem

`Jido.AI.ReAct` is the working pattern for "stateful slice that contributes a typed DSL block to the host":

```elixir
# lib/jido/ai/re_act.ex
defmodule Jido.AI.ReAct do
  use Jido.Slice                              # slice schema, signal_routes, capabilities
  slice do
    name "ai_react"
    schema Zoi.object(%{...})                 # state at agent.state[:ai]
  end
  signal_routes do
    route "ai.react.ask",  Actions.Ask
    route "ai.react.turn", Actions.LlmTurn
    ...
  end

  use Jido.Slice.Extension, host_section: :react   # opens `react do … end` on host
end
```

Users mount it through the agent DSL:

```elixir
defmodule MyApp.MathAgent do
  use Jido.Agent, extensions: [Jido.AI.ReAct]

  agent do
    name "math"
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [Jido.AI.TestActions.TestAdd]
    system_prompt "You are precise."
  end

  slices do
    slice :ai, Jido.AI.ReAct
  end
end
```

`Jido.Pod` is structurally identical:

- It owns a slice at `:pod` (state schema: `topology, topology_version, mutation, metadata`).
- It contributes a typed DSL block to the host (`pod do topology … plugin … end`).
- It auto-mounts the pod plugin (today via the bespoke `AttachPodPlugin` transformer; could be the standard slice-extension `host_section: :pod` mechanism).
- It validates the resolved pod plugin advertises capability `:pod`.

Yet today `Jido.Pod` is a **sibling** of `Jido.Agent` instead of an extension *on* `Jido.Agent`:

```elixir
# lib/jido/pod.ex
defmodule Jido.Pod do
  use Spark.Dsl,
    default_extensions: [extensions: [Jido.Dsl.Pod]],
    untyped_extensions?: false,
    opt_schema: [
      extensions: [...],         # duplicated from Jido.Agent
      middleware: [...],         # duplicated from Jido.Agent (added in task 0053)
      jido: [...],               # duplicated from Jido.Agent
      default_slices: [...]      # duplicated from Jido.Agent
    ]

  defmacro __using__(opts) do    # duplicates Jido.Agent's __using__ shadow-extension logic
    env = __CALLER__
    user_extensions = ...
    shadow_extensions = ...
    new_opts = ...
    super(new_opts)
  end

  def handle_opts(opts) do       # delegates to Jido.Agent.handle_opts/1 (so why is it separate?)
    agent_quote = Jido.Agent.handle_opts(opts)
    quote do
      unquote(agent_quote)
      @before_compile Jido.Pod.BeforeCompile
    end
  end
end
```

The duplication exists because `Spark.Dsl` validates options at compile time against the *use'd module's* opt_schema, not its parent's — even with `add_extensions: [Jido.Dsl.Agent]` in `Jido.Dsl.Pod`, Spark does not auto-inherit opt_schema entries. So every keyword users want to pass (`middleware:`, `jido:`, etc.) has to be re-declared on `Jido.Pod`'s opt_schema.

Underneath: every piece of the pod surface is doing extra work that the slice-extension machinery already does:

| Today | What it does | Equivalent for ReAct |
|---|---|---|
| `Jido.Dsl.Pod` (Spark DSL) | Adds `pod do topology … end` section + delegates to `Jido.Dsl.Agent` via `add_extensions:`. | `Jido.Slice.Extension` macro emits `__jido_host_section__/0` + `__jido_host_extension_module__/0`; the agent's `extensions: [Jido.AI.ReAct]` keyword adds the shadow extension automatically. |
| `Jido.Pod.Transformers.ResolveTopology` | Reads the `pod do topology … end` block, normalizes `topology` to `%Topology{}`, persists `:resolved_topology`. | Slice-extension's typed-section block opts are read by `WalkExtensions.read_contributed_block/2` and merged into the slice's config; the slice's own seed pipeline runs through `__seed_plugin_slice__/2`. The topology *normalization* lives in the slice itself (a `pre_seed/1` callback or similar). |
| `Jido.Pod.Transformers.AttachPodPlugin` | Walks `default_slices` override + `pod do plugin SomeModule end`, picks the right pod-plugin module, adds it to the agent's slice mounts at path `:pod`, validates capability `:pod`. | Today: `extensions: [Jido.Pod]` opens the host section; `slices do slice :pod, Jido.Pod end` mounts. The "auto-mount from `extensions:`" half is the only extra: a slice extension that wants to be auto-mounted on every host needs a transformer that *also* adds a `SliceMount{path: :pod, module: …}` to the host's `:slices` section when the host doesn't already have one. |
| `Jido.Pod.BeforeCompile` | Overrides `new/1` to seed `state.pod = %{topology: …, topology_version: …}` from the pod's persisted `:resolved_topology`. | Slice-extension's existing `__seed_plugin_slice__/2` already merges instance config + user state through the slice's schema. The pod's seed is just `%{topology: topology, topology_version: topology.version}` — that's the slice's *config* now, set by the typed section. The bespoke `new/1` override goes away. |
| `Jido.Pod`'s `defmacro __using__` | Re-implements `Jido.Agent.__shadow_extensions__` discovery for the pod's own `extensions:` keyword. | Disappears — there is no `use Jido.Pod`; the user writes `use Jido.Agent, extensions: [Jido.Pod]` like any other slice extension. |
| `Jido.Pod`'s `handle_opts` | Delegates to `Jido.Agent.handle_opts/1` and wires `@before_compile Jido.Pod.BeforeCompile`. | Disappears — no `Jido.Pod` Spark DSL, no `handle_opts`. |
| `Jido.Pod`'s `opt_schema` (`extensions:`, `middleware:`, `jido:`, `default_slices:` duplicated) | Spark options validation. | Disappears — users write `use Jido.Agent`, the agent's opt_schema is the source of truth. |

`Jido.Pod` itself becomes a thin module: just the slice DSL (state schema, signal_routes, capabilities), the slice-extension host-section declaration (`use Jido.Slice.Extension, host_section: :pod`), and the runtime helper functions (`Pod.get/3`, `Pod.lookup_node/2`, `Pod.fetch_state/1`, `Pod.fetch_topology/1`, `Pod.put_topology/2`, `Pod.update_topology/2`, `Pod.mutate/3`, `Pod.mutate_and_wait/3`, `Pod.nodes/1`, `Pod.ensure_node/3`, `Pod.reconcile/2`).

## Target shape

```elixir
defmodule MyApp.Fulfillment do
  use Jido.Agent, extensions: [Jido.Pod]

  agent do
    name "fulfillment"
  end

  pod do
    topology %{
      warehouse: %{agent: MyApp.Warehouse, manager: :fulfillment_warehouse, activation: :eager},
      shipping:  %{agent: MyApp.Shipping,  manager: :fulfillment_shipping,  activation: :eager}
    }
  end

  # `slices do slice :pod, Jido.Pod end` is added automatically by the
  # pod's auto-mount transformer when `extensions: [Jido.Pod]` is present
  # and the user hasn't already declared a different mount for `:pod`.
end
```

`Jido.Pod` itself:

```elixir
defmodule Jido.Pod do
  @moduledoc "..."

  use Jido.Plugin                              # plugin = slice + middleware behaviour
                                               # (pod's middleware half handles the
                                               # signal pipeline lifecycle hooks)

  slice do
    name "pod"
    schema Zoi.object(%{
      topology: Zoi.any() |> Zoi.optional(),
      topology_version: Zoi.integer() |> Zoi.default(1),
      mutation: Zoi.object(%{...}) |> Zoi.default(%{...}),
      metadata: Zoi.map() |> Zoi.default(%{})
    })
  end

  signal_routes do
    route "mutate", Actions.Mutate
    route "jido.pod.query.nodes", Actions.QueryNodes
    route "jido.pod.query.topology", Actions.QueryTopology
    route "jido.agent.child.started", Actions.MutateProgress
    route "jido.agent.child.exit",    Actions.MutateProgress
  end

  capabilities do
    capability :pod
  end

  use Jido.Slice.Extension, host_section: :pod

  @doc false
  @spec __jido_host_contribution__() :: Spark.Dsl.Section.t()
  def __jido_host_contribution__ do
    %Spark.Dsl.Section{
      name: :pod,
      describe: "Pod topology and runtime options.",
      schema: [
        topology: [
          type: {:custom, __MODULE__, :validate_topology, []},
          required: true,
          doc: "..."
        ],
        plugin: [
          type: :any,
          default: nil,
          doc: "Override the reserved pod plugin (default: `Jido.Pod` itself)."
        ]
      ]
    }
  end

  # ──────────────────────────────────────────────────────────────────
  # Runtime helpers (unchanged signatures and semantics)
  # ──────────────────────────────────────────────────────────────────

  defdelegate get(manager, key, opts \\ []), to: __MODULE__.Runtime
  defdelegate lookup_node(server, name), to: __MODULE__.Runtime
  ...
end
```

The `pod do topology … end` block's typed `topology` field is normalized through the section's `validate_topology/1` callback (replaces the work `Jido.Pod.Transformers.ResolveTopology` does). The block's `topology` and `plugin` keys flow into the slice's config map via the existing `WalkExtensions.read_contributed_block/2` plumbing. The slice's seed pipeline (`Jido.Agent.__seed_plugin_slice__/2`) validates the merged config through the pod's slice schema and produces the initial `agent.state[:pod]` map — the same map `BeforeCompile` builds today, but built through the same code path every other slice goes through.

## What moves where

| Today | Target |
|---|---|
| `lib/jido/pod.ex` `use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Pod]]` + duplicated opt_schema + `defmacro __using__` + `handle_opts` | Delete the Spark DSL declaration. `Jido.Pod` becomes `use Jido.Plugin` + `use Jido.Slice.Extension, host_section: :pod`. |
| `lib/jido/dsl/pod.ex` (Spark DSL extension defining `pod do topology … end` section) | Delete. The host section is built by `Jido.Pod.__jido_host_contribution__/0`. |
| `lib/jido/dsl/pod/transformers/attach_pod_plugin.ex` | Replace with a small auto-mount transformer that adds `SliceMount{path: :pod, module: Jido.Pod, options: …}` to the host's `:slices` section when the user has `Jido.Pod` in `extensions:` and hasn't already mounted `:pod` themselves. Lives next to the slice-extension's `__after_compile__` machinery — or inlined into `Jido.Slice.Extension` as a generic "auto-mount me at my own host_section name" capability for slice extensions that opt in. |
| `lib/jido/dsl/pod/transformers/resolve_topology.ex` | Delete. Topology normalization moves into a `validate_topology/1` `:custom` validator on the pod section's schema. |
| `lib/jido/pod/before_compile.ex` | Delete. `agent.state[:pod]` is seeded by the standard slice config-seeding pipeline. The `topology/0` accessor on the host module — used by `Pod.fetch_topology/1` to read the canonical topology from the pod-wrapped module — moves to `Jido.Pod.Info.topology/1` (introspection on the host module via Spark dsl_state). |
| `Jido.Pod.Plugin` (the plugin module that owns `:pod` slice state today) | Folds into `Jido.Pod` itself. The slice + middleware halves coexist on one module via `use Jido.Plugin`. |
| `lib/jido/pod/topology_state.ex` (`@pod_state_key PluginInfo.path(Plugin)` etc.) | Hard-code `@pod_state_key :pod` since the pod's mount path is reserved. Or read it from `Jido.Pod.__jido_host_section__/0` (returns `:pod`). |
| `lib/jido/pod/mutable.ex` (`@pod_state_key PluginInfo.path(Plugin)`) | Same — hard-code `:pod` or read `__jido_host_section__/0`. |
| `use Jido.Pod` callsites (every in-tree pod, livebooks, examples, docs, tests) | Rewrite to `use Jido.Agent, extensions: [Jido.Pod]`. Topology stays in `pod do topology … end`. |
| `Pod.get/3`, `Pod.lookup_node/2`, `Pod.mutate/3`, `Pod.fetch_state/1`, `Pod.fetch_topology/1`, `Pod.reconcile/2`, etc. | Stay on `Jido.Pod` — they are runtime helpers that take an agent module + manager and don't care about how the pod was declared. |

## Auto-mount question (open design point)

The current `extensions: [Jido.Pod]` flow needs to **automatically** mount `Jido.Pod` at `:pod`. Without a default mount, users would have to write both:

```elixir
use Jido.Agent, extensions: [Jido.Pod]
slices do slice :pod, Jido.Pod end
```

…on every pod, which defeats the point of `use Jido.Agent, extensions: [Jido.Pod]` being the one-line declaration. Two ways to provide auto-mount:

1. **Pod-specific transformer** — `Jido.Pod.Transformers.AutoMount` runs after `WalkExtensions` and adds a `SliceMount{path: :pod, module: Jido.Pod}` if the host has `Jido.Pod` in `extensions:` and doesn't already have a `:pod` mount. Same shape as today's `AttachPodPlugin` but smaller (no schema validation — that's the slice's own job now).
2. **Generic slice-extension auto-mount** — opt-in flag on `use Jido.Slice.Extension, host_section: :pod, auto_mount: true`. The slice-extension machinery emits a transformer that auto-mounts the slice at its `host_section` path on every host that lists it in `extensions:`. ReAct could keep `auto_mount: false` (today's behaviour: user must declare `slices do slice :ai, Jido.AI.ReAct end` explicitly) or flip to `true` if that's the more common pattern.

Recommend **option 2** (generic auto-mount in `Jido.Slice.Extension`) because (a) it eliminates a Pod-specific code path, (b) it's a useful capability for any slice that has a single canonical mount path, and (c) it keeps Pod's surface as small as possible. Decide during the planning step.

## Acceptance

- `lib/jido/dsl/pod.ex` deleted.
- `lib/jido/dsl/pod/transformers/attach_pod_plugin.ex` and `lib/jido/dsl/pod/transformers/resolve_topology.ex` deleted (or replaced by the auto-mount transformer per §Auto-mount).
- `lib/jido/pod/before_compile.ex` deleted.
- `lib/jido/pod/plugin.ex` folded into `lib/jido/pod.ex` (so `Jido.Pod` is the slice-extension module; no separate `Jido.Pod.Plugin`).
- `lib/jido/pod.ex`'s `use Spark.Dsl, …`, duplicated opt_schema, `defmacro __using__`, and `handle_opts` deleted.
- `git grep -nE 'use Jido\\.Pod\\b' lib/ test/ guides/` returns zero hits — every pod callsite migrated to `use Jido.Agent, extensions: [Jido.Pod]`.
- `git grep -nE 'Jido\\.Dsl\\.Pod\\b' lib/ test/` returns zero hits.
- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix test --include e2e` clean (Pod runtime tests, mutation tests, integration tests all pass).
- Cheat sheets regenerated (`mix spark.cheat_sheets`); `documentation/dsls/DSL-Jido.Pod.md` removed and `documentation/dsls/DSL-Jido.Agent.md` shows the `pod do … end` host section under "Contributed sections".

## Out of scope

- Any change to pod runtime semantics (topology resolution, mutation state machine, ack/await selectors, child-lifecycle signals, etc.). Pure shape refactor.
- Renaming `Jido.Pod.*` modules outside of folding `Jido.Pod.Plugin` into `Jido.Pod`. The `Jido.Pod.{Runtime, Mutable, Mutation, TopologyState, Topology, BusPlugin}` namespace stays.
- Pod's `BusPlugin` (`lib/jido/pod/bus_plugin.ex`) — that's a separate plugin handling the bus subscription lifecycle. It already uses `use Jido.Plugin` and is mounted by the user, not by Pod's auto-attach. Untouched.
- Per the "NO LEGACY ADAPTERS" rule (`guides/tasks/README.md`): no shim that accepts both `use Jido.Pod` and `use Jido.Agent, extensions: [Jido.Pod]`. Rewrite every callsite.

## Risks

- **The auto-mount design is the load-bearing decision.** Picking a Pod-specific transformer keeps the change tiny but adds a Pod-only code path. Picking generic `auto_mount: true` on `Jido.Slice.Extension` is a slightly bigger change but eliminates the special case. Worth a short ADR before the implementation PR.
- **Topology validation moving from a transformer to a `:custom` schema validator** changes when the validation runs. The transformer ran during the agent module's compile pipeline; the schema validator runs every time `Spark.Dsl.Extension.get_opt(module, [:pod], :topology)` is read. Cache the normalized result via `Transformer.persist(:resolved_topology, …)` if profile shows the validator is hot.
- **`Pod.fetch_topology/1` reads the canonical topology from the host module's persisted state.** Today that's `module.topology()` (emitted by `BeforeCompile`). After the refactor it should be `Jido.Pod.Info.topology(module)` reading from the host's Spark dsl_state. Any caller that still calls `MyPod.topology()` needs updating — there should be one or two; `git grep '\\.topology()'` finds them.
- **Migration churn.** Every `use Jido.Pod` callsite (in-tree pods, livebooks, example pods, test fixtures) needs rewriting to `use Jido.Agent, extensions: [Jido.Pod]`. Same scope as the in-tree migrations in task 0053; a single-pass `git grep` + sed.
- **`@before_compile Jido.Pod.BeforeCompile` is implicitly relied on by the `topology/0` and `pod?/0` accessors** that downstream code (e.g. `Pod.fetch_topology/1` falling through to `agent_module.topology()`, `Pod.pod?/1` checking `function_exported?(mod, :pod?, 0)`) calls. Replace with `Jido.Pod.Info.topology/1` and `Jido.Pod.Info.pod?/1` (the latter just checks if `:pod` capability is in `Jido.Dsl.Agent.Info.capabilities(module)`).
