---
name: Task 0063 — Replace custom Jido callbacks with Spark patterns
description: Task 0061 collapsed `Jido.Pod` from its sibling-of-`Jido.Agent` shape into a single module that is both `use Jido.Slice` (for the slice DSL) and `use Spark.Dsl.Extension` (for the contributed `pod do …` section), with a `Jido.Pod.Transformers.RegisterContribution` transformer that calls `Spark.Dsl.Transformer.persist/3` directly on `:jido_contributed_sections`. That pattern obsoletes Jido's `__jido_host_section__/0` / `__jido_host_contribution__/0` / `__jido_host_extension_module__/0` accessors, the `Jido.Slice.Extension.__after_compile__/2` shadow-extension synthesis, `Jido.Agent.__shadow_extensions__/2`, the `:jido_user_extensions` persisted key, and `Jido.Dsl.Agent.Transformers.DiscoverExtensions`. Four extensions still ride the legacy callback path: `Jido.AI.ReAct`, `Jido.Memory.Slice`, `Jido.Identity.Slice`, `Jido.Thread.Slice`. This task migrates each to Pod's shape, removes the now-dead machinery, hardens the section-collision check so it covers all extensions (today `DiscoverExtensions` only sees legacy slices), and tackles the parallel duplication on the instance side — `use Jido`'s macro-emitted `__otp_app__/0` / `__jido_storage__/0` / `__default_slices__/0` accessors mirror `Jido.Dsl.Instance.Transformers.GenerateAccessors`'s output and should collapse onto the Spark-extension path.
---

# Task 0063 — Replace custom Jido callbacks with Spark patterns

- Depends on: [task 0061](0061-collapse-pod-into-agent-extension.md) (the pod migration introduced the Pod-style `RegisterContribution` pattern this task generalises).
- Blocks: nothing — independent of the rename chain (0044–0050) and the dashboard chain (0054–0060).
- Leaves tree: **green**.

## Problem

Task 0061 already established the right pattern. From [ce1e52c](#) `lib/jido/pod.ex`:

```elixir
defmodule Jido.Pod do
  use Jido.Slice                                    # slice DSL — schema, signal_routes, capabilities

  slice do … end
  signal_routes do … end
  capabilities do capability :pod end

  @pod_section %Spark.Dsl.Section{
    name: :pod,
    describe: "Pod topology and runtime options.",
    schema: [topology: [type: :any, default: %{}, doc: "…"]]
  }

  use Spark.Dsl.Extension,                          # contributes the `pod do … end` section
    sections: [@pod_section],
    transformers: [
      Jido.Pod.Transformers.RegisterContribution,   # persists into :jido_contributed_sections
      Jido.Pod.Transformers.ResolveTopology         # runs before WalkExtensions
    ]
end
```

`Jido.Pod.Transformers.RegisterContribution` ([lib/jido/pod/transformers/register_contribution.ex](lib/jido/pod/transformers/register_contribution.ex)) is the load-bearing piece — 8 lines of `Spark.Dsl.Transformer.persist/3` that join Pod into the host's `:jido_contributed_sections` map without any `__jido_*__/0` callback:

```elixir
def transform(dsl_state) do
  contributed = Transformer.get_persisted(dsl_state, :jido_contributed_sections, %{})
  {:ok, Transformer.persist(dsl_state, :jido_contributed_sections,
                             Map.put(contributed, Jido.Pod, :pod))}
end
```

Four other extensions still go through the legacy path:

| Extension | File | Pattern |
|---|---|---|
| `Jido.AI.ReAct` | [lib/jido/ai/re_act.ex:133](lib/jido/ai/re_act.ex) | `use Jido.Slice.Extension, host_section: :react` + overrides `__jido_host_contribution__/0` to hand-write the section |
| `Jido.Memory.Slice` | [lib/jido/memory/slice.ex:76](lib/jido/memory/slice.ex) | `use Jido.Slice.Extension, host_section: :memory` — auto-derives section from `config_schema/0` |
| `Jido.Identity.Slice` | [lib/jido/identity/slice.ex:51](lib/jido/identity/slice.ex) | Same pattern as Memory |
| `Jido.Thread.Slice` | [lib/jido/thread/slice.ex:58](lib/jido/thread/slice.ex) | Same pattern as Memory |

The legacy path generates three `__jido_*__/0` accessors, synthesises `<Slice>.HostExtension` via `__after_compile__`, persists the user's extension list as `:jido_user_extensions`, and walks it inside `DiscoverExtensions`. None of that is needed once each extension self-registers Pod-style.

The same pattern holds at the instance layer. `Jido.Dsl.Instance.Transformers.GenerateAccessors` already emits `__otp_app__/0` / `__jido_storage__/0` / `__default_slices__/0` for the Spark path (`use Jido` was deliberately written to "mirror `Jido.Dsl.Instance` so the macro and the Spark extension share the same accessor surface" — [lib/jido.ex:87-91](lib/jido.ex)). The macro mirror is duplicate code; with the slice-extension migration done, the Pod-style "be a Spark extension directly" pattern fits `use Jido` too.

### What task 0061 left on the table

Reading `ce1e52c` reveals four things the Pod migration could not address inside its own scope, and which 0063 picks up:

1. **`Jido.Pod.Transformers.RegisterContribution` declares `after?(Jido.Dsl.Agent.Transformers.DiscoverExtensions), do: true`** ([lib/jido/pod/transformers/register_contribution.ex:27](lib/jido/pod/transformers/register_contribution.ex)). That ordering exists only so `DiscoverExtensions` doesn't overwrite Pod's entry afterwards. Once `DiscoverExtensions` is deleted, the clause becomes dead weight; the transformer just needs `before?(WalkExtensions)`.
2. **Section-name collision detection in `DiscoverExtensions` only guards legacy slices.** The check at [lib/jido/dsl/agent/transformers/discover_extensions.ex:35-37](lib/jido/dsl/agent/transformers/discover_extensions.ex) iterates the result of walking `__jido_host_section__/0` callbacks. Pod escapes the check — its `RegisterContribution` runs *after* `DiscoverExtensions`, so a user that mounts both `Jido.Pod` and a hypothetical legacy slice that picks `:pod` would not be flagged at compile time. The collision check belongs in a verifier (or at the start of `WalkExtensions`) that iterates the final `:jido_contributed_sections` map regardless of how each entry got there.
3. **`Jido.Slice.Extension.build_section/2` auto-derives the contributed section from `config_schema/0` via `SchemaTranslate`** ([lib/jido/slice/extension.ex:91-100](lib/jido/slice/extension.ex)). Memory/Identity/Thread rely on it; ReAct hand-writes its section. The auto-derivation is real value and survives the migration as a public helper (`Jido.Slice.Extension.build_section/1`) callable from inside an extension's module body. Throwing it away would force every slice to hand-write a `%Spark.Dsl.Section{}` literal.
4. **Two consumers of `__jido_storage__/0`** still call it via `function_exported?` ([lib/jido/persist.ex:475-476](lib/jido/persist.ex), [lib/jido/agent/instance_manager.ex:406-407](lib/jido/agent/instance_manager.ex)). They migrate to `Spark.Dsl.Extension.get_persisted(jido, :storage)` once `Jido.Dsl.Instance` becomes the single accessor source.

## Target shape

Each migrated slice flattens into Pod's two-macro shape. Memory as the worked example (Identity/Thread are mechanical):

```elixir
defmodule Jido.Memory.Slice do
  use Jido.Slice

  slice do
    name "memory"
    schema Zoi.object(%{…})
  end
  signal_routes do … end
  capabilities do … end

  # Replaces `use Jido.Slice.Extension, host_section: :memory`.
  # build_section/1 is the surviving public helper from the old
  # Jido.Slice.Extension.build_section/2 — auto-derives the
  # %Spark.Dsl.Section{} from config_schema/0 via SchemaTranslate.
  @memory_section Jido.Slice.Extension.build_section(__MODULE__, :memory)

  use Spark.Dsl.Extension,
    sections: [@memory_section],
    transformers: [{Jido.Slice.Extension.RegisterContribution, section: :memory}]
end
```

`Jido.Slice.Extension.RegisterContribution` is the generic version of `Jido.Pod.Transformers.RegisterContribution`. Slice modules pass their host section name as a transformer option; the transformer reads the option and persists `Map.put(contributed, slice_module, section)` into `:jido_contributed_sections`. Pod's bespoke transformer collapses onto this generic too (or stays Pod-specific — either works, since the per-extension transformer is now a 5-line file).

For ReAct, which hand-writes its section, the shape is identical except the `@react_section` literal is built inline rather than via `build_section/1`.

The legacy macro keeps backwards-compatible ergonomics for slices that don't want to know about Spark's section internals:

```elixir
defmodule Jido.Slice.Extension do
  defmacro __using__(opts) do
    section_name = Keyword.fetch!(opts, :host_section)

    quote bind_quoted: [section_name: section_name] do
      @host_section Jido.Slice.Extension.build_section(__MODULE__, section_name)

      use Spark.Dsl.Extension,
        sections: [@host_section],
        transformers: [{Jido.Slice.Extension.RegisterContribution, section: section_name}]
    end
  end

  # Surviving helper from the old build_section/2 — same SchemaTranslate
  # pipeline, callable from any module.
  def build_section(module, section_name) do
    %Spark.Dsl.Section{
      name: section_name,
      describe: section_describe(module),
      schema: SchemaTranslate.translate(SliceInfo.config_schema(module))
    }
  end
end
```

The three `__jido_*__/0` accessors, the `defoverridable __jido_host_contribution__: 0`, and the entire `__after_compile__/2` shadow-synthesis path disappear. ReAct (which used the override hook) writes `@host_section %Spark.Dsl.Section{...}` literally and calls `use Spark.Dsl.Extension` directly, skipping the convenience macro the same way Pod does.

For the agent side:

```elixir
# lib/jido/agent.ex __using__/1 — was:
extensions = Keyword.get(opts, :extensions, [])
shadows = Enum.flat_map(extensions, &Jido.Agent.__shadow_extensions__(&1, env))
@persist {:jido_user_extensions, user_extensions}

# becomes:
extensions = Keyword.get(opts, :extensions, [])
# … pass straight to use Spark.Dsl. The extensions' own
# RegisterContribution transformers populate :jido_contributed_sections.
```

For the instance side:

```elixir
defmodule Jido do
  # Was: defmacro __using__ that emits __jido_storage__/0, __otp_app__/0, etc.
  defmacro __using__(opts) do
    quote do
      use Spark.Dsl,
        default_extensions: [extensions: [Jido.Dsl.Instance]],
        otp_app: unquote(opts[:otp_app])
      # The instance options pass through to the instance section;
      # Jido.Dsl.Instance.Transformers.GenerateAccessors already emits
      # the runtime accessors. The macro mirror is gone.
    end
  end
end
```

## What moves where

| Today | Target |
|---|---|
| `Jido.AI.ReAct`'s `use Jido.Slice.Extension, host_section: :react` + `def __jido_host_contribution__` override ([lib/jido/ai/re_act.ex:133-165](lib/jido/ai/re_act.ex)) | Hand-written `@react_section %Spark.Dsl.Section{…}` literal + `use Spark.Dsl.Extension, sections: [@react_section], transformers: [{Jido.Slice.Extension.RegisterContribution, section: :react}]`. Same shape Pod uses. |
| `Jido.Memory.Slice`'s `use Jido.Slice.Extension, host_section: :memory` ([lib/jido/memory/slice.ex:76](lib/jido/memory/slice.ex)) | `@memory_section Jido.Slice.Extension.build_section(__MODULE__, :memory)` + `use Spark.Dsl.Extension, …`. The convenience macro `use Jido.Slice.Extension, host_section: :memory` *expands* to this shape. |
| `Jido.Identity.Slice`, `Jido.Thread.Slice` | Same as Memory — convenience macro expands to the Pod shape under the hood. |
| `Jido.Slice.Extension.__using__/1` ([lib/jido/slice/extension.ex:44-66](lib/jido/slice/extension.ex)) — emits `__jido_host_section__/0`, `__jido_host_contribution__/0`, `__jido_host_extension_module__/0`, `defoverridable`, and `@after_compile {Jido.Slice.Extension, :__after_compile__}` | Rewritten to emit `@host_section Jido.Slice.Extension.build_section(__MODULE__, …)` + `use Spark.Dsl.Extension, sections: [@host_section], transformers: [{Jido.Slice.Extension.RegisterContribution, section: …}]`. No `__jido_*__/0` accessors, no `defoverridable`, no `@after_compile`. |
| `Jido.Slice.Extension.__after_compile__/2` ([lib/jido/slice/extension.ex:69-82](lib/jido/slice/extension.ex)) | **Deleted.** No more shadow-extension synthesis. |
| `Jido.Slice.Extension.build_section/2` ([lib/jido/slice/extension.ex:90-97](lib/jido/slice/extension.ex)) | **Stays.** Becomes the public helper for slices that want auto-derivation from `config_schema/0`. ReAct can also opt into it instead of hand-writing the section. |
| New: `Jido.Slice.Extension.RegisterContribution` | Generic version of `Jido.Pod.Transformers.RegisterContribution` — takes `section:` as a transformer option, persists `Map.put(contributed, owning_module, section)` into `:jido_contributed_sections`. `before?(Jido.Dsl.Agent.Transformers.WalkExtensions)`. **No `after?(DiscoverExtensions)` clause** — the transformer is gone. |
| `Jido.Pod.Transformers.RegisterContribution` ([lib/jido/pod/transformers/register_contribution.ex](lib/jido/pod/transformers/register_contribution.ex)) | Either deleted (Pod uses the generic instead) or kept and stripped of its `after?(DiscoverExtensions)` clause. The bespoke version is fine to keep — it documents Pod's reservation of the `:pod` section. |
| `Jido.Agent.__shadow_extensions__/2` ([lib/jido/agent.ex:114, 133-149](lib/jido/agent.ex)) | **Deleted.** With each extension self-registering, no shadow-injection step is needed; agents pass `extensions:` straight through to `use Spark.Dsl`. |
| `:jido_user_extensions` persisted key ([lib/jido/agent.ex:343](lib/jido/agent.ex)) | **Deleted.** No consumer once `DiscoverExtensions` is gone. |
| `Jido.Dsl.Agent.Transformers.DiscoverExtensions` (full module) | **Deleted.** Its only callers (`WalkExtensions`) read `:jido_contributed_sections` directly. |
| Section-name collision detection ([discover_extensions.ex:35-37, 60-65](lib/jido/dsl/agent/transformers/discover_extensions.ex)) | Moves to a new verifier `Jido.Dsl.Agent.Verifiers.NoContributedSectionCollisions` (or folded into the existing `Jido.Dsl.Agent.Verifiers.NoSectionNameCollisions` at [lib/jido/dsl/agent/verifiers/no_section_name_collisions.ex](lib/jido/dsl/agent/verifiers/no_section_name_collisions.ex)). The check iterates `Map.keys(:jido_contributed_sections)` and flags duplicate section values regardless of how each entry got registered — closing the Pod-vs-legacy gap. |
| `Jido.__jido_storage__/0`, `__otp_app__/0`, `__default_slices__/0` ([lib/jido.ex:96-116](lib/jido.ex)) | `use Jido` becomes `use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Instance]]`. `Jido.Dsl.Instance.Transformers.GenerateAccessors` already emits the same three accessors; the macro mirror is gone. |
| The "macro mirrors extension" stanza at [lib/jido.ex:87-91](lib/jido.ex) | Deleted along with the macro mirror. `Jido.Dsl.Instance` is the single source. |
| Call sites: `Jido.Persist` ([persist.ex:475-476](lib/jido/persist.ex)) and `Jido.Agent.InstanceManager` ([instance_manager.ex:406-407](lib/jido/agent/instance_manager.ex)) — both `function_exported?(jido, :__jido_storage__, 0)` checks | Replace with `Spark.Dsl.Extension.get_persisted(jido, :storage)` (or keep calling `__jido_storage__/0` since `GenerateAccessors` still emits it — the duplicate macro mirror is what disappears, not the accessor function). |

## Acceptance

- `git grep -nE "__jido_host_section__|__jido_host_contribution__|__jido_host_extension_module__" -- lib/` returns zero hits.
- `git grep -n "__shadow_extensions__" -- lib/` returns zero hits.
- `git grep -n ":jido_user_extensions" -- lib/` returns zero hits (`:jido_contributed_sections` stays — it is the interchange format).
- `lib/jido/dsl/agent/transformers/discover_extensions.ex` deleted.
- `Jido.Slice.Extension.__after_compile__/2` deleted; the `@after_compile` hook is gone.
- All five contributing extensions (`Jido.Pod`, `Jido.AI.ReAct`, `Jido.Memory.Slice`, `Jido.Identity.Slice`, `Jido.Thread.Slice`) use the same shape: slice DSL + `@<name>_section %Spark.Dsl.Section{...}` (or `Jido.Slice.Extension.build_section/2` for auto-derived ones) + `use Spark.Dsl.Extension, sections: [...], transformers: [...]`.
- Section-name collision detection lives in a verifier that reads the final `:jido_contributed_sections` map and catches collisions across the legacy and Pod paths uniformly. A regression test mounts `Jido.Pod` plus a stub extension that picks `:pod` and asserts the verifier raises.
- `use Jido` is `use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Instance]]`. The "macro mirrors extension" stanza in `lib/jido.ex` is deleted.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test --include e2e` all clean (the local quality gate, including the LM Studio integration suite).
- Cheat sheets regenerated (`mix spark.cheat_sheets`); `documentation/dsls/DSL-Jido.Memory.Slice.md` (and siblings) show the contributed `memory do … end` section without Jido-specific shims.

## Out of scope

- Mount fan-out semantics ([task 0062](0062-multi-instance-slice-mount-fan-out.md)) — orthogonal.
- Reworking `Jido.Dsl.Instance`'s DSL surface (the `instance do …` section schema, the existing transformer behaviour). This task collapses the runtime `use Jido` macro onto it; it does not redesign the instance options.
- Spark `dsl_patches` with `%AddEntity{}`. `dsl_patches` only adds entities to an existing host section; the four migrating slices contribute *whole* sections (`memory`, `identity`, `thread`, `react`), so the synthesized-extension-via-RegisterContribution path is the right one. `dsl_patches` is unused.
- Per the "NO LEGACY ADAPTERS" rule (`guides/tasks/README.md`): no shim retaining the `__jido_host_section__/0` (etc.) accessors alongside the persisted state. Rewrite every caller in one pass.

## Risks

- **`SchemaTranslate` exercise.** Memory/Identity/Thread today let `Jido.Slice.Extension.build_section/2` auto-derive the contributed section from their `config_schema/0`. The migration calls the same code from a different position (module-attribute-eval time inside the slice, not `__after_compile__` post-compile). `SchemaTranslate` should be position-agnostic, but the implementation must verify by regenerating cheat sheets for all three slices and diffing against the pre-migration output.
- **`@host_section` evaluation timing.** `@host_section Jido.Slice.Extension.build_section(__MODULE__, :memory)` evaluates the helper at module-attribute-assignment time, *before* `use Spark.Dsl.Extension` reads the attribute. `Jido.Slice.Extension.build_section/2` calls `Jido.Dsl.Slice.Info.config_schema(__MODULE__)`, which reads from the slice's already-compiled `Jido.Slice` DSL state. The slice DSL's transformers must have run before the `@host_section` line. Today's call site (in `__after_compile__`) always runs post-compile, so timing is implicit; the new call site relies on textual order: `slice do … end` block macros emit before the `@host_section` line. Verify the ordering holds for every migrated slice; if it doesn't, fall back to building the section inside the `RegisterContribution` transformer (which has the full dsl_state available).
- **ReAct's hand-written contribution.** `Jido.AI.ReAct.__jido_host_contribution__/0` ([lib/jido/ai/re_act.ex:136-160ish](lib/jido/ai/re_act.ex)) hand-builds a `%Spark.Dsl.Section{}` with custom Zoi-aware schema entries that `SchemaTranslate` can't synthesise. After the migration, ReAct writes the same struct as a literal in the module body. No information loss; the `defoverridable` mechanism just turns into "skip the convenience helper".
- **External callers of `__jido_*__/0` accessors.** Anything outside `lib/` (example slices, downstream apps, livebooks) that calls `Slice.__jido_host_section__()` will break. The audit found one in-tree caller (`Jido.Dsl.Agent.Transformers.DiscoverExtensions`, deleted) and the framework's own slice-extension wrapper (rewritten). Out-of-tree consumers get a single migration paragraph in the changelog.
- **Pod's `RegisterContribution` keeping its `after?(DiscoverExtensions)` clause** would be a silent no-op once that transformer is deleted — Spark's transformer-ordering machinery presumably handles "after a missing transformer" gracefully, but verify. The cleaner move is to drop the clause as part of this task.
- **Migration of the `__jido_storage__/0` consumers** in `Jido.Persist` and `Jido.Agent.InstanceManager` is mechanical but needs care — both files use `function_exported?` defensively. The defensive shape is no longer needed once `Jido.Dsl.Instance.Transformers.GenerateAccessors` is the single source; rewrite to a direct call. If any downstream code relied on the *runtime* accessor (rather than just the persisted value), the rewrite must keep the function alive — `GenerateAccessors` already emits it, so the change is just deleting the macro mirror, not the accessor itself.
