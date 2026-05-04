# 0025. Extension directory layout: `slices/` `middlewares/` `plugins/` `directives/`

- Status: Accepted
- Implementation: Complete
- Date: 2026-04-30
- Related ADRs: [0014](0014-slice-middleware-plugin.md) (slice / middleware /
  plugin split), [0019](0019-actions-mutate-state-directives-do-side-effects.md)
  (actions mutate, directives are side effects),
  [0023](0023-spark-dsl-and-registerable-extensions.md) (Spark DSL for extension
  surfaces).
- Related commits: implementation tasks [0043–0052](../tasks/README.md)

## Context

After [ADR 0023](0023-spark-dsl-and-registerable-extensions.md) the composition
vocabulary is final: **slices** are stateful contributions to an agent's
`state`, **middleware** wraps the signal pipeline, **plugins** are slice +
middleware in one module, and **directives** are bare structs that actions
return as side-effect requests. Every `use Jido.X` site is a typed Spark DSL.

The directory layout under `lib/jido/` did not get the same treatment. The DSL
bases (`agent.ex`, `slice.ex`, `plugin.ex`, …), the runtime (`agent_server.ex`,
`scheduler.ex`, …), and the DSL machinery (`dsl/`) live alongside the **built-in
extensions** (`memory/`, `identity/`, `thread/`, `ai/re_act.ex`,
`middleware/retry.ex`, `plugin/fsm.ex`) without any visual separation. A new
contributor cannot grep the tree to learn "what extensions ship with Jido"
without reading the source.

Three more shape problems compound this:

1. **Three modules named `*.Agent` are not agents.** `Jido.Memory.Agent`,
   `Jido.Identity.Agent`, and `Jido.Thread.Agent` are pure-function helpers that
   read/write one slice's portion of `agent.state` on a `%Jido.Agent{}` struct,
   bypassing the signal pipeline. They violate ADR 0019 by providing a
   state-mutation backdoor, and they violate the post-ADR-0023 naming rule that
   says "if it's named `*.Agent` it does `use Jido.Agent`." Their only callers
   are tests, plus `Jido.Identity.Profile` (itself only used by tests).

2. **Directives are scattered.** Framework directives live under
   `lib/jido/agent/directive/` (3 files: `cron`, `cron_cancel`, `reply`) plus 9
   more _inlined_ structs inside the umbrella `lib/jido/agent/directive.ex`
   itself (`Emit`, `Error`, `Spawn`, `SpawnAgent`, `AdoptChild`, `StopChild`,
   `Schedule`, `RunInstruction`, `Stop`). Slice-owned directives live next to
   their slice (`lib/jido/ai/directive/{llm_call, tool_exec}.ex`,
   `lib/jido/pod/directive/{start_node, stop_node}.ex`). The slice-owned
   placement is right; the framework-directive umbrella is buried under `agent/`
   and half its contents aren't files.

3. **Stale code from the ADR-0023 migration.** `Jido.Telemetry.Config` is 9
   `@deprecated` shims with zero callers, pointing at `Jido.Observe.Config.*`.
   `Jido.Sensors.Heartbeat` is a test fixture currently parked in `lib/`.

## Decision

We will reshape `lib/jido/` so the directory tree itself encodes the
post-ADR-0023 architecture.

### 1. Top-level extension directories

Built-in registerable extensions move under three new top-level directories:

- `lib/jido/slices/` — every built-in slice. One file per slice
  (`slices/memory.ex`), supporting types in a same-named subdirectory
  (`slices/memory/{state,space}.ex`, `slices/memory/actions/*.ex`).
- `lib/jido/middlewares/` — every built-in middleware (`middlewares/retry.ex`,
  `middlewares/persister.ex`).
- `lib/jido/plugins/` — every built-in plugin (`plugins/fsm.ex`).

Module names follow the directory: `Jido.Slices.Memory`,
`Jido.Middlewares.Retry`, `Jido.Plugins.FSM`. The redundant `.Slice` / `.Plugin`
/ `.Middleware` suffix drops because the namespace already carries it.

The framework directories (`action.ex`, `agent.ex`, `slice.ex`, etc. — the DSL
bases, runtime, and machinery) stay where they are. The visual signal "this is a
built-in extension you can mount on your own agent" vs "this is framework
infrastructure" comes from the top-level dir name.

### 2. Directives lift to `lib/jido/directives/`

Framework directives — those that any action across the framework can emit —
move from `lib/jido/agent/directive/` and the inlined structs in
`lib/jido/agent/directive.ex` to `lib/jido/directives/`, one struct per file.
Modules rename `Jido.Agent.Directive.Emit` → `Jido.Directives.Emit`, etc. The
umbrella becomes `Jido.Directives` at `lib/jido/directives.ex`, slimmed to
typespecs and module-doc.

**Slice-owned directives ride along with their slice** in a `directives/`
subdirectory: `Jido.AI.Directive.LLMCall` becomes
`Jido.Slices.AiReact.Directives.LLMCall` at
`lib/jido/slices/ai_react/directives/llm_call.ex`. Pod's directives stay under
`lib/jido/pod/directive/` because pod itself is a special agent kind whose
directives are tightly coupled to its runtime; the directive subdir parallels
the AI ReAct slice's `directives/` subdir, just under pod's existing tree.

### 3. The data-type module becomes `<Slice>.State`

`Jido.Memory` (the struct stored at `agent.state[:memory]`) becomes
`Jido.Slices.Memory.State`. `Jido.Identity` → `Jido.Slices.Identity.State`.
`Jido.Thread` → `Jido.Slices.Thread.State`. The slice DSL module itself takes
the suffix-less name (`Jido.Slices.Memory` is the slice declaration, the thing
users put in `extensions: [...]`).

Splitting these two roles ends the namespace ambiguity: today `Jido.Memory` is
both the data type _and_ the namespace prefix for
`Jido.Memory.{Slice, Space, Actions}`. After this ADR, `Jido.Slices.Memory` is
the slice (one canonical entry), `Jido.Slices.Memory.State` is the struct value,
and the rest of the tree (`.Space`, `.Actions.*`) lives under the same
namespace.

### 4. Hard cut, no shims

Per the "NO LEGACY ADAPTERS" rule in
[`guides/tasks/README.md`](../tasks/README.md), no module aliases, no
`@deprecated` accessors, no keyword-form fallbacks. Every in-tree caller updates
in the same commit as the rename. External users follow the migration guide
refresh in [task 0052](../tasks/0052-docs-and-cheat-sheets-refresh.md); the
framework remains pre-1.0.

### 5. Companion cleanups

In the same chain we:

- **Delete the four misnamed/test-only helpers**: `Jido.Memory.Agent`,
  `Jido.Identity.Agent`, `Jido.Thread.Agent`, and `Jido.Identity.Profile`. Tests
  rewrite to use `cmd/2` + the slice's actions for writes (the production path)
  and direct read from `agent.state` for reads.
- **Move `Jido.Sensors.Heartbeat` to `test/support/`** since its only callers
  are tests.
- **Delete `Jido.Telemetry.Config`** — 9 `@deprecated` shims with zero callers.

The `Jido.AI` facade (`lib/jido/ai.ex`) stays put as a thin entry point. A
future ADR may extract it (and the AI ReAct slice) into a separate package so
users without LLM agents do not pull `req_llm`; that decision is not folded into
this one.

## Consequences

- **The directory tree teaches the architecture.** A reader runs `ls lib/jido/`
  and sees `slices/`, `middlewares/`, `plugins/`, `directives/` — those are the
  four extension surfaces. Everything else is framework. This is the same
  property `app/`, `lib/`, and `test/` give Mix projects: the structure is the
  documentation.
- **Naming convention is now total.** `*.Slice` modules `use Jido.Slice`;
  `*.Middleware` use `Jido.Middleware`; `*.Plugin` use `Jido.Plugin`; `*.Action`
  use `Jido.Action`; `*.Sensor` use `Jido.Sensor`; `*.Directive` is a struct.
  Nothing ending in `*.Agent` exists outside actual `use Jido.Agent` callsites.
- **One state-mutation path.** Deleting the `*.Agent` helpers removes the only
  in-tree backdoor around ADR 0019. Tests now exercise the same `cmd/2`
  action-dispatch path as production code.
- **Free `mix spark.cheat_sheets` regen.** The DSLs themselves don't change
  shape; only module names move. Cheat-sheet output only needs to pick up the
  new module names in the cross-references.
- **Hard break for external users.** Every user `alias Jido.Memory.Slice` /
  `alias Jido.Plugin.FSM` / `alias Jido.Agent.Directive.Emit` rewrites. The
  migration is mechanical (regex-driven) and we ship a section in
  `guides/migration-spark-dsl.md` walking through the most common renames.
- **Pod stays at `lib/jido/pod/`.** Pod is a special agent kind whose pod-only
  plugin (`Jido.Pod.Plugin`) and the surrounding runtime machinery (`actions/`,
  `directive/`, `mutation/`, `topology*`, `runtime.ex`, `transformers/`) are
  tightly coupled to pod runtime, topology, and mutation pipelines. Promoting
  that pod-runtime-coupled code to `Jido.Plugins.Pod*` would split pod across
  two trees for no win. The exception is scoped to runtime-coupled machinery
  only — the auxiliary `BusPlugin` module that originally lived under
  `lib/jido/pod/bus_plugin.ex` was reclassified to `Jido.Slices.ChildBus` (task
  0064), since it depends on framework-level child-lifecycle signals
  (`jido.agent.child.*`, emitted by `Jido.AgentServer` for any child-spawning
  agent), not on pod runtime / topology / mutation, and so belongs in the same
  bucket as the other built-in slices.
- **`*.State` rename is the one contentious choice.** `Jido.Slices.Memory.State`
  reads cleanly to most readers; some may prefer `Jido.Slices.Memory.Data` or
  keeping the suffix-less form (the data type and the slice would share a
  module). The execution task
  ([0044](../tasks/0044-move-rename-memory-slice.md)) finalises the name;
  ADR-level commitment is to "split the two roles into two modules with distinct
  names," not specifically to `.State`.
- **The directives umbrella file shrinks dramatically.** Today
  `lib/jido/agent/directive.ex` defines 9 inline structs. After Task 0050 it
  disappears (moved to `lib/jido/directives.ex` as a slim umbrella). The 12
  directive structs each get their own file.
- **Tasks 0043–0052 are the rollout.** Phase A (0043) deletes the helpers;
  Phases B–D (0044–0050) do the moves; Phase E (0051) does the small companion
  cleanups; Phase F (0052) refreshes docs and flips this ADR's status to
  Accepted / Complete.

## Alternatives considered

- **Move directories but keep module names.** `lib/jido/slices/memory/slice.ex`
  defining `Jido.Memory.Slice`. Zero API break. Cost: file-path-to-module-name
  convention is broken; IDEs that auto-resolve modules from paths get confused;
  future readers cannot infer the file location from the module name. Rejected
  because the convention is load-bearing for navigation.
- **Keep the existing layout; just rename the misnamed helpers.** Smallest
  change. Addresses the naming bug but leaves the framework/extension separation
  invisible in the tree. Rejected because the user explicitly asked for the
  reorg.
- **Move the data type into the slice DSL module.** `Jido.Slices.Memory` would
  be both the slice declaration and the struct (`%Jido.Slices.Memory{}`). No
  `*.State` rename. Cost: conflates two roles in one file (Spark DSL
  declaration + struct + functional API), the file grows large, and pattern
  matching on the struct value (`%Jido.Slices.Memory{} = value`) reads worse
  than `%Jido.Slices.Memory.State{} = value` because the slice module is also
  what users register at the agent boundary. Rejected on readability grounds.
- **Top-level `lib/jido/extensions/` with subdirs `slices/`, `middlewares/`,
  `plugins/`.** One umbrella for all extension types. Costs an extra layer of
  nesting (`lib/jido/extensions/slices/memory.ex`) for one word of grouping.
  Rejected as not worth the depth.
- **Promote pod-runtime-coupled plugins to `lib/jido/plugins/pod/`.** Splits pod
  across `lib/jido/pod/` and `lib/jido/plugins/pod/` for the runtime-coupled
  portion (the pod-only plugin behaviour plus the actions, directives, mutation,
  topology, and runtime modules that share its data shape). Rejected for the
  reasons listed in Consequences. The rejection is scoped to pod-runtime-coupled
  code; the bus auxiliary that did **not** depend on pod runtime was
  reclassified to `Jido.Slices.ChildBus` in task 0064.
