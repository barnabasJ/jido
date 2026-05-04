---
name:
  Task 0064 — Classify BusPlugin as a slice; close out the
  extension-classification audit
description:
  Audit every in-tree `use Jido.{Slice,Middleware,Plugin}` module against the
  post-ADR-0025 / post-task-0061 / post-FSM-reclass reality and bring the one
  outlier into line. `Jido.Pod.BusPlugin` is the only `use Jido.Plugin` module
  left in `lib/`; it has no middleware behaviour, no `call/4`, no `init/1` — it
  is functionally a slice. Reclassify it as `use Jido.Slice`, rename
  `Jido.Pod.BusPlugin` → `Jido.Slices.ChildBus`, and move
  `lib/jido/pod/bus_plugin{.ex,/}` → `lib/jido/slices/child_bus{.ex,/}`. Update
  ADR 0025's "Pod stays at `lib/jido/pod/`" clause to match (post-task-0061 Pod
  is a single slice + Spark extension, no longer a sibling agent kind, so the
  "split pod across two trees" objection no longer applies to bus-wiring
  auxiliaries that don't touch pod topology / runtime / mutation). Surface — but
  do not resolve — the open question of whether the `Jido.Plugin` abstraction
  itself stays once it has zero in-tree users.
---

# Task 0064 — Classify BusPlugin as a slice; close out the extension-classification audit

- Implements: closes the audit pass started by
  [ADR 0025](../adr/0025-extension-directory-layout.md) and [b5a1c49](#) (FSM
  reclassification).
- Depends on: [task 0061](0061-collapse-pod-into-agent-extension.md)
  (Pod-is-a-slice is what makes the BusPlugin move structurally clean).
- Blocks: nothing.
- Leaves tree: **green**.

## Context

After tasks 0044–0050 + b5a1c49 + task 0061, the in-tree extension surface looks
like this:

| File                                | Module                       | `use`             | Location matches namespace?         |
| ----------------------------------- | ---------------------------- | ----------------- | ----------------------------------- |
| `lib/jido/slices/memory.ex`         | `Jido.Slices.Memory`         | `Jido.Slice`      | ✓                                   |
| `lib/jido/slices/identity.ex`       | `Jido.Slices.Identity`       | `Jido.Slice`      | ✓                                   |
| `lib/jido/slices/thread.ex`         | `Jido.Slices.Thread`         | `Jido.Slice`      | ✓                                   |
| `lib/jido/slices/ai_react.ex`       | `Jido.Slices.AiReact`        | `Jido.Slice`      | ✓                                   |
| `lib/jido/slices/fsm.ex`            | `Jido.Slices.FSM`            | `Jido.Slice`      | ✓                                   |
| `lib/jido/middlewares/persister.ex` | `Jido.Middlewares.Persister` | `Jido.Middleware` | ✓                                   |
| `lib/jido/middlewares/retry.ex`     | `Jido.Middlewares.Retry`     | `Jido.Middleware` | ✓                                   |
| `lib/jido/pod.ex`                   | `Jido.Pod`                   | `Jido.Slice`      | ✓ (deliberate exception, see below) |
| `lib/jido/pod/bus_plugin.ex`        | `Jido.Pod.BusPlugin`         | **`Jido.Plugin`** | ✗ — misclassified                   |

`Jido.Pod` itself stays at `lib/jido/pod.ex` (not `lib/jido/slices/pod.ex`)
because it has substantial first-class supporting machinery —
`lib/jido/pod/{actions,directive,mutation,topology,runtime.ex,info.ex,queries.ex,topology_state.ex,mutable.ex,transformers}`
— and moving the slice declaration alone would split the feature tree without
helping anyone navigate. The other slices in `lib/jido/slices/` have at most an
actions subdirectory; pod's footprint is an order of magnitude larger.

`Jido.Pod.BusPlugin` is a different story:

```
$ rg -nP "@behaviour Jido\.Middleware|def call\(|def init\(" lib/jido/pod/bus_plugin*
(empty)
```

It declares `slice do … end`, `signal_routes do … end`, `capabilities do … end`.
It never implements `Jido.Middleware`. It uses `use Jido.Plugin` purely because
Plugin = Slice + Middleware-behaviour, and the project happened to call this
kind of module a "plugin" before the FSM reclass. Today that's exactly the shape
that triggered b5a1c49 for FSM:

> commit 067b2f5 had already converted it from `use Jido.Plugin` to
> `use Jido.Slice` — it has no middleware behaviour, no `on_signal/4` callback,
> and is purely a slice. Task 0049's spec mistakenly carried the old "plugin"
> label forward.

The structural-coupling argument that ADR 0025 §"Pod stays" gives for keeping
`Jido.Pod.BusPlugin` under `lib/jido/pod/` does not survive inspection:

- It references `Jido.Pod.BusPlugin.AutoSubscribeChild` / `AutoUnsubscribeChild`
  (its own actions) and `Jido.Signal.Bus`.
- It does **not** reference `Jido.Pod.Runtime`, `Jido.Pod.Topology`,
  `Jido.Pod.TopologyState`, `Jido.Pod.Mutation`, or `Jido.Pod.Mutable`.
- The signals it routes (`jido.agent.child.started`, `jido.agent.child.exit`)
  are emitted by `Jido.AgentServer` for **any** agent that boots as a child of a
  parent — not by Pod (`lib/jido/agent_server/directive_executors.ex:310`,
  `lib/jido/agent_server.ex:1780`). Pod consumes them too, but it does not
  produce them.

The plugin is, in other words, a generic "auto-subscribe each child of this
agent to a named bus" slice. It works in any host that spawns children with
parent-tracking — most usefully a pod, but the dependency runs through the
framework's child-lifecycle protocol, not through pod machinery.

## Goal

After this task:

1. `lib/jido/slices/child_bus.ex` defines `Jido.Slices.ChildBus` with
   `use Jido.Slice` (was `lib/jido/pod/bus_plugin.ex` / `Jido.Pod.BusPlugin` /
   `use Jido.Plugin`).
2. `lib/jido/slices/child_bus/auto_subscribe_child.ex` defines
   `Jido.Slices.ChildBus.AutoSubscribeChild`.
3. `lib/jido/slices/child_bus/auto_unsubscribe_child.ex` defines
   `Jido.Slices.ChildBus.AutoUnsubscribeChild`.
4. `lib/jido/pod/bus_plugin.ex` and `lib/jido/pod/bus_plugin/` are gone; the
   `lib/jido/pod/` tree contains only the Pod-runtime-coupled machinery the
   ADR-0025 exception was actually meant to protect.
5. ADR 0025 §"Pod stays" is rewritten to scope the exception to
   pod-runtime-coupled code only (i.e., `lib/jido/pod.ex` itself plus its
   `actions/`, `directive/`, `mutation/`, `topology*`, `runtime.ex`,
   `transformers/` neighbours), and explicitly notes that `BusPlugin` was
   reclassified out.
6. `Jido.Plugin` has zero in-tree users. The abstraction stays defined
   (`lib/jido/plugin.ex`, `lib/jido/dsl/plugin.ex`,
   `lib/jido/dsl/plugin/info.ex`, etc.) — that is a separate decision (see "Open
   question" below).
7. Tree compiles clean; full test suite passes.

## Approach

### File moves

```sh
mkdir -p lib/jido/slices/child_bus
git mv lib/jido/pod/bus_plugin.ex                       lib/jido/slices/child_bus.ex
git mv lib/jido/pod/bus_plugin/auto_subscribe_child.ex   lib/jido/slices/child_bus/auto_subscribe_child.ex
git mv lib/jido/pod/bus_plugin/auto_unsubscribe_child.ex lib/jido/slices/child_bus/auto_unsubscribe_child.ex
rmdir lib/jido/pod/bus_plugin
```

### Module renames

| Before                                    | After                                       |
| ----------------------------------------- | ------------------------------------------- |
| `Jido.Pod.BusPlugin`                      | `Jido.Slices.ChildBus`                      |
| `Jido.Pod.BusPlugin.AutoSubscribeChild`   | `Jido.Slices.ChildBus.AutoSubscribeChild`   |
| `Jido.Pod.BusPlugin.AutoUnsubscribeChild` | `Jido.Slices.ChildBus.AutoUnsubscribeChild` |

### Reclassification

In `lib/jido/slices/child_bus.ex`:

```diff
-  use Jido.Plugin
+  use Jido.Slice
```

The `slice do … end`, `signal_routes do … end`, and `capabilities do … end`
blocks stay verbatim; they are already the `Jido.Slice` DSL surface (Plugin
re-exports it).

### Caller updates

```sh
rg -nP "Jido\.Pod\.BusPlugin" lib/ test/ guides/
```

Expected callers as of writing: just the three files being moved (each
references its siblings) plus the `slice :child_bus, …` mount example in the
moduledoc. Update those four occurrences. Ignore historical task / ADR docs (the
FSM reclass left them alone — same precedent).

### Moduledoc cleanup

While you are in `lib/jido/slices/child_bus.ex`, fix three claims that go stale
with the reclass:

1. The "## Host contribution" paragraph mentioning _"This plugin does not opt
   into `Jido.Slice.Extension`"_ should say "this slice" (or just delete the
   paragraph — the negative claim adds little once the file is named
   `child_bus.ex` with `use Jido.Slice`).
2. The mount example should use the new module name and the slice atom that
   matches: `slice :child_bus, {Jido.Slices.ChildBus, %{bus: :my_bus}}`.
3. The reference to `Jido.Plugin.Routes.expand_routes/1` in "## Routes" still
   applies (slice and plugin share the route-expansion path), but the prose
   should drop the "This plugin" framing.

### Validate the audit

After the move, re-run the audit grep:

```sh
rg -nP "^  use Jido\.(Plugin|Slice|Middleware)\b" lib/ --type elixir
```

Expected output: every `Jido.Slice` line is under `lib/jido/slices/` **except**
`lib/jido/pod.ex`. Every `Jido.Middleware` line is under
`lib/jido/middlewares/`. Zero `Jido.Plugin` lines. If the output differs, the
audit is incomplete.

### ADR 0025 update

Edit `guides/adr/0025-extension-directory-layout.md`:

- §"Consequences", "Pod stays at `lib/jido/pod/`" bullet (lines ~165–169):
  rewrite to scope the exception to pod-runtime-coupled machinery only. Drop the
  `Jido.Pod.BusPlugin` reference. Add a sentence noting that `BusPlugin` was
  reclassified to `Jido.Slices.ChildBus` because its dependency on
  framework-level child-lifecycle signals (not on pod runtime / topology /
  mutation pipelines) puts it in the same bucket as the other built-in slices.
- §"Alternatives considered", "Promote pod plugins to `lib/jido/plugins/pod/`"
  bullet (lines ~209–211): the rejection still holds for pod-runtime-coupled
  code; tighten the wording so it doesn't read as also rejecting the BusPlugin
  move.

The ADR's status stays **Accepted / Implementation Complete**; this is a scope
clarification, not a reversal.

## Acceptance criteria

- [ ] `git mv` of all three files completed; `lib/jido/pod/bus_plugin{.ex,/}`
      does not exist.
- [ ] All three module renames applied;
      `rg -nP "Jido\.Pod\.BusPlugin" lib/ test/` returns nothing.
- [ ] `lib/jido/slices/child_bus.ex` says `use Jido.Slice`.
- [ ] Audit grep confirms zero `use Jido.Plugin` lines in `lib/`.
- [ ] ADR 0025 "Pod stays" wording updated.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] `mix test` passes (1935+ tests, 0 failures).
- [ ] One commit, prefixed `refactor:` matching the FSM-reclass commit style
      (`b5a1c49`).

## Out of scope (deferred to follow-up tasks, not dropped)

- **Moving `Jido.Pod` itself into `lib/jido/slices/`** —
  [task 0065](0065-move-pod-into-slices.md). The "split feature tree" objection
  ADR 0025 originally raised collapses once the move is whole-subtree rather
  than declaration-only, since every other built-in slice already has the
  `lib/jido/slices/X.ex` + `lib/jido/slices/X/…` shape. Pod's footprint is
  bigger than the others' but follows the same convention.
- **The `Jido.Plugin` abstraction question** —
  [task 0066](0066-decide-jido-plugin-abstraction.md). After this task lands,
  `Jido.Plugin` has zero in-tree users; either keep (with a smoke-fixture so the
  path stays exercised) or deprecate (collapse the four-extension vocabulary to
  three). Decision-first task.
- **Public-API migration notes** —
  [task 0067](0067-migration-notes-rename-chain.md). Consolidates the
  before/after rename map for the entire 0044–0066 chain so external users
  upgrade in one pass instead of spelunking individual task docs.
