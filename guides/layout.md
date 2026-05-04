# Layout — directory and namespace conventions

This guide describes the directory shape under `lib/jido/` and the naming
conventions an out-of-tree extension author should mirror. The convention was
established by ADR 0025 (`guides/adr/0025-extension-directory-layout.md`) and
enforced by tasks 0043–0052 (`guides/tasks/README.md`).

## The four extension surfaces

Jido has four kinds of registerable extensions. Each gets its own top-level
directory:

```
lib/jido/
├── slices/        # built-in slices (state contributions)
├── middlewares/   # built-in middlewares (signal-pipeline wrappers)
└── directives/    # framework-level directives (side-effect requests)
```

A fourth surface — **plugins** (`Jido.Plugins.*`, at `lib/jido/plugins/`) — is
part of the convention but currently has no in-tree members. A plugin is
`Slice + Middleware` in one module; both prior in-tree plugins
(`Jido.Plugin.FSM` and `Jido.Pod.BusPlugin`) were reduced to pure slices and now
live at `lib/jido/slices/fsm.ex` and `lib/jido/slices/child_bus.ex`
respectively. Out-of-tree plugin authors still mirror the shape under
`MyOrg.Plugins.<Name>`.

Each built-in extension is **one file at the top of its surface dir** (the entry
point) plus a **same-named subdirectory** for supporting types and actions. For
example, the Memory slice:

```
lib/jido/slices/memory.ex                 # Jido.Slices.Memory (slice DSL)
lib/jido/slices/memory/state.ex           # Jido.Slices.Memory.State (data type)
lib/jido/slices/memory/space.ex           # Jido.Slices.Memory.Space (supporting type)
lib/jido/slices/memory/actions/*.ex       # Jido.Slices.Memory.Actions.* (8 actions)
lib/jido/slices/memory/transformers/      # Spark transformer for typed-block contribution
```

Same shape for `lib/jido/slices/identity/`, `lib/jido/slices/thread/`,
`lib/jido/slices/ai_react/`. Middlewares are leaf modules without a sibling
subdirectory (Retry, Persister).

## Framework infrastructure stays put

The directories _under_ `lib/jido/` (not the four surface dirs) hold framework
code, not extensions:

```
lib/jido/agent/         # agent struct, instance manager, schema
lib/jido/agent_server/  # the runtime GenServer (signal pipeline, lifecycle)
lib/jido/slice/         # framework base for slices (DSL host module lives at lib/jido/slice.ex)
lib/jido/plugin/        # framework plugin internals (Config, Instance, Requirements, …)
lib/jido/middleware.ex  # framework middleware base (DSL host)
lib/jido/dsl/           # Spark DSL definitions for every `use Jido.X` shape
lib/jido/exec/          # action exec runtime
lib/jido/persist.ex     # checkpoint / hibernate / thaw
lib/jido/storage/       # storage adapters (ETS, Redis, file)
…
```

These files are the framework. They're not registerable extensions themselves
and don't move to a `*/` plural directory.

## Pod follows the slice convention

Pod is structurally a slice: `lib/jido/slices/pod.ex` does `use Jido.Slice` just
like Memory, Identity, Thread, AiReact, and FSM. Its supporting machinery
(actions, directives, mutation, topology, runtime, transformers) lives under
`lib/jido/slices/pod/`:

```
lib/jido/slices/pod.ex                  # Jido.Slices.Pod (slice DSL)
lib/jido/slices/pod/runtime.ex          # Jido.Slices.Pod.Runtime
lib/jido/slices/pod/topology.ex         # Jido.Slices.Pod.Topology
lib/jido/slices/pod/mutation.ex         # Jido.Slices.Pod.Mutation
lib/jido/slices/pod/directive/          # Jido.Slices.Pod.Directive.* (slice-scoped directives)
lib/jido/slices/pod/actions/            # Jido.Slices.Pod.Actions.*
lib/jido/slices/pod/transformers/       # Spark transformers
```

Pod is bigger than the other slices, but bigger is a quantitative difference —
the `slices/X.ex` + `slices/X/` shape scales because each slice's machinery
stays under its own subdirectory. The auxiliary that originally lived under
`lib/jido/pod/bus_plugin.ex` was reclassified to `Jido.Slices.ChildBus`
(task 0064) — it depends on framework-level child-lifecycle signals, not on pod
runtime.

## Out-of-tree authors mirror the convention

A third-party library shipping `MyOrg.Slices.Slack` (a slice) mirrors the
in-tree shape:

```
lib/my_org/slices/slack.ex                # MyOrg.Slices.Slack (slice DSL)
lib/my_org/slices/slack/state.ex          # MyOrg.Slices.Slack.State (data type)
lib/my_org/slices/slack/actions/*.ex      # MyOrg.Slices.Slack.Actions.*
```

Same pattern for middlewares (`MyOrg.Middlewares.<Name>`), plugins
(`MyOrg.Plugins.<Name>`), and directives (`MyOrg.Directives.<Name>`).

## Directives: framework vs slice-owned

Two homes for directive structs, depending on who owns the side effect:

- **Framework directives** live at `lib/jido/directives/<snake>.ex` because any
  action across the framework can emit them. Module name:
  `Jido.Directives.<Name>`. Examples: `Jido.Directives.Emit`,
  `Jido.Directives.SpawnAgent`, `Jido.Directives.Cron`.

- **Slice-owned directives** live next to their slice in a `directives/`
  subdirectory. Module name follows the slice's namespace. Examples:
  - `Jido.Slices.AiReact.Directives.LLMCall`,
    `Jido.Slices.AiReact.Directives.ToolExec` — only the AI ReAct slice's
    actions emit these.
  - `Jido.Slices.Pod.Directive.StartNode`, `Jido.Slices.Pod.Directive.StopNode`
    — pod-runtime-specific.

The rule: if a directive's exec impl needs slice-private types or runtime, it's
slice-owned. If it's a building block any agent can emit, it lifts to framework.

## Naming convention summary

| Surface                 | Directory                                       | Module prefix                           | Data-type subname |
| ----------------------- | ----------------------------------------------- | --------------------------------------- | ----------------- |
| Slice                   | `lib/jido/slices/<snake>/`                      | `Jido.Slices.<Name>`                    | `<Name>.State`    |
| Middleware              | `lib/jido/middlewares/<snake>.ex`               | `Jido.Middlewares.<Name>`               | —                 |
| Plugin                  | `lib/jido/plugins/<snake>/`                     | `Jido.Plugins.<Name>`                   | —                 |
| Directive (framework)   | `lib/jido/directives/<snake>.ex`                | `Jido.Directives.<Name>`                | —                 |
| Directive (slice-owned) | `lib/jido/slices/<slice>/directives/<snake>.ex` | `Jido.Slices.<Slice>.Directives.<Name>` | —                 |

Action modules under a slice live at
`lib/jido/slices/<slice>/actions/<snake>.ex` →
`Jido.Slices.<Slice>.Actions.<Name>`.

## Why the convention exists

ADR 0025 established the rule for two reasons:

1. **The directory tree should signal architectural role.** A new contributor
   running `ls lib/jido/` should immediately see the four extension surfaces
   alongside framework infrastructure, without reading source.

2. **Out-of-tree authors copy what they see.** A consistent convention in `jido`
   makes the right shape obvious for a third-party library author.
