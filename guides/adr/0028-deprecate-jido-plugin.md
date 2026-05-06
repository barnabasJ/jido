# 0028. Deprecate `Jido.Plugin` — collapse the four-shape vocabulary to three

- Status: Accepted
- Implementation: Pending (executed by
  [task 0068](../tasks/0068-remove-jido-plugin.md))
- Date: 2026-05-06
- Related commits / PRs: —
- Supersedes (in part): the four-shape vocabulary introduced in
  [0014](0014-slice-middleware-plugin.md), echoed by
  [0011](0011-retire-strategy-plugins-are-control-flow.md),
  [0013](0013-slices-middleware-plugins.md),
  [0023](0023-spark-dsl-and-registerable-extensions.md),
  [0025](0025-extension-directory-layout.md). Those ADRs keep their original
  status; this ADR retires only the `Plugin` extension shape.

## Context

[ADR 0014](0014-slice-middleware-plugin.md) introduced three extension tiers —
Slice, Middleware, Plugin — where Plugin was "the combo when both are needed in
one module." Two follow-up tasks
([0064](../tasks/0064-classify-and-relocate-pod-bus-plugin.md) and
[0065](../tasks/0065-move-pod-into-slices.md)) reclassified every in-tree plugin
(`Jido.Plugin.FSM`, `Jido.Pod.BusPlugin`) as a bare `use Jido.Slice` because
none of them implemented `@behaviour Jido.Middleware`. Task
[0066](../tasks/0066-decide-jido-plugin-abstraction.md) then audited what
remained and asked whether the abstraction earns its keep.

The audit found:

1. **DSL surface is identical to Slice.** `Jido.Dsl.Plugin` is one line of
   substance — `use Spark.Dsl.Extension, sections: Jido.Dsl.Slice.sections()`.
   `Jido.Dsl.Plugin.Info` is fourteen `defdelegate`s to `Jido.Dsl.Slice.Info`.
   Every option that `slice do … end` accepts on a Plugin (`otp_app`,
   `config_schema`, `requires`, `schedules`) is already declared by
   `Jido.Dsl.Slice` itself (`lib/jido/dsl/slice.ex:38, 43, 137`).

2. **Mount-layer features have no production callers.** The supposedly
   Plugin-specific instance semantics — `as:` aliasing, derived `route_prefix`,
   `Application.get_env(otp_app, mod)` config merge, runtime `requires:`
   validation — appear nowhere in `lib/` outside Plugin's own machinery. Their
   only exercise is docstrings inside `lib/jido/plugin/*` and Plugin's
   self-tests under `test/jido/plugin/`. The instance layer that justified
   Plugin's existence on paper turned out to be dead code at production-time.

3. **Middleware injection is one line.** `lib/jido/plugin.ex` is 24 lines; the
   meaningful body is `quote do: @behaviour Jido.Middleware` in `handle_opts/1`.
   Anything `use Jido.Plugin` does that `use Jido.Slice` doesn't, the user can
   do explicitly with one extra line.

4. **The cost of keeping is real.** ~800 LOC across eight framework files
   (`lib/jido/plugin.ex`,
   `lib/jido/plugin/{config,instance,requirements,routes,schedules,spec}.ex`,
   `lib/jido/dsl/plugin.ex`, `lib/jido/dsl/plugin/info.ex`), a parallel
   persistence vocabulary (`:plugin_instances` / `:plugin_specs` /
   `:plugin_paths` / `:validated_plugin_routes` / `:expanded_plugin_routes` /
   `:expanded_plugin_schedules` / `:all_plugin_routes`), a classifier branch in
   `Jido.Dsl.Agent.Transformers.WalkExtensions.classify_mount/2`, and a
   four-shape vocabulary that doesn't resolve to anything observable.

The conceptual case for keeping — "stateful slice + signal-pipeline wrap is a
real pattern" — is sound, but five tasks and one full Slice/Middleware refactor
later, no in-tree extension has needed both halves in the same module. The
deferred follow-ups from ADR 0014 (`CircuitBreaker`, `LogErrors`, `StopOnError`,
`Logger`) can each be implemented as middleware-only or as a slice plus an
explicit middleware registration.

## Decision

We will remove `Jido.Plugin` from the framework. The vocabulary collapses from
four extension shapes (Slice / Middleware / Plugin / Directive) to three (Slice
/ Middleware / Directive). Modules that genuinely want both halves combine
`use Jido.Slice` with `@behaviour Jido.Middleware` directly:

```elixir
defmodule MyOrg.Slices.RateLimiter do
  use Jido.Slice
  @behaviour Jido.Middleware

  slice do
    name "rate_limiter"
    schema Zoi.object(%{counters: Zoi.map() |> Zoi.default(%{})})
  end

  signal_routes do
    route "rate_limiter.tick", MyOrg.Slices.RateLimiter.Actions.Tick
  end

  @impl Jido.Middleware
  def call(signal, _opts, _ctx, next), do: next.(signal)
end
```

The slice gets registered under `slices do … end` on the host agent and the same
module gets added to the agent's `middleware: […]` list — the auto-mounting that
Plugin did is replaced by an explicit middleware registration, which is
consistent with how every middleware in the framework is wired today.

The DSL surface is unchanged because `use Jido.Slice` already declares every
section that `use Jido.Plugin` did. Mount-layer features that Plugin had on
paper but no caller used (`as:` aliasing, `route_prefix`, otp_app config merge,
runtime `requires:` validation) go away with the abstraction; if any of them
prove desirable later, they get lifted into Slice's transformer pipeline as
standalone features rather than gated behind a separate extension shape.

Execution lives in [task 0068](../tasks/0068-remove-jido-plugin.md). The package
is at v2.2.0; this removal lands as a breaking change and the next release bumps
to v3.0.0.

## Consequences

- **One fewer abstraction in the public vocabulary.** Guides collapse from four
  extension surfaces to three. New contributors and out-of-tree authors learn
  one less concept; the "Plugin or Slice?" question disappears, which is the
  question the audit found nobody had answered correctly even inside the tree
  (FSM and BusPlugin were both Plugins-by-default until task 0064 reclassified
  them).

- **~800 LOC and a parallel persistence vocabulary deleted.** `lib/jido/plugin/`
  and `lib/jido/dsl/plugin/` go away entirely. The agent transformer pipeline
  drops `:plugin_instances` / `:plugin_specs` / `:plugin_paths` /
  `:validated_plugin_routes` / `:expanded_plugin_routes` /
  `:expanded_plugin_schedules` / `:all_plugin_routes` and operates only on
  slice-side keys.

- **Breaking change for any external Plugin user.** The migration is mechanical
  (`use Jido.Plugin` → `use Jido.Slice` + `@behaviour Jido.Middleware` + add the
  module to the agent's `middleware:` list), but it is a hard break. Released
  under v3.0.0 with the recipe in `guides/migration-spark-dsl.md` and
  `guides/migration.md`.

- **Three deferred ADR-0014 follow-ups become explicit-middleware decisions.**
  `CircuitBreaker` (which originally motivated the "stateful middleware" case)
  ships as `use Jido.Slice` + `@behaviour Jido.Middleware` if it needs counters,
  or middleware-only if it doesn't. `Logger`, `LogErrors`, `StopOnError` are all
  stateless and ship middleware-only. The Plugin tier was speculative; its
  concrete candidates resolve cleanly without it.

- **No backward-compat shim.** A `Jido.Plugin` macro that aliases to
  `use Jido.Slice` + `@behaviour Jido.Middleware` was considered and rejected:
  the abstraction has no in-tree exercise to validate the shim against, the
  migration is one extra line, and shipping a deprecation alias creates a long
  tail of dual-shape code paths the framework would have to keep supporting.

- **Some Plugin-only features regress.** `Jido.Plugin.Routes.detect_conflicts/1`
  (multi-mount route conflict detection) and
  `Jido.Plugin.Requirements.validate_all/2` (compile-time `requires:`
  validation) had no in-tree consumers but were tested in isolation. If either
  is desired post-removal, it gets lifted into a slice-side transformer in a
  separate task. Slice's `requires do … end` section continues to be parseable
  and accessible via introspection; what disappears is the runtime/compile-time
  validator that walks it.

- **`otp_app` in the slice DSL becomes informational only.** Plugin's
  `Jido.Plugin.Config` was the only path that resolved `otp_app` into runtime
  config via `Application.get_env`. Slice declares the field in its schema
  (`lib/jido/dsl/slice.ex:38`) for introspection but doesn't merge from the
  application environment. Either the field stays as a marker (and a future task
  wires runtime resolution into Slice) or it gets removed from the DSL schema;
  task 0068 leaves it informational.

## Alternatives considered

- **Keep Plugin and add a smoke fixture + verifier.** The original task-0066
  KEEP path. Rejected after the second-level audit: the mount-layer features
  that justified the abstraction (`as:`, `route_prefix`, otp_app config, runtime
  `requires:`) have zero production callers, so a smoke fixture would exercise
  machinery nothing else uses, and the verifier would only enforce a constraint
  that exists because the abstraction exists. Pure overhead.

- **Deprecate-only Phase A, defer deletion.** `@deprecated` annotation + compile
  warning + migration recipe in v2.x, full removal in a later v3.x. Rejected:
  jido is at v2.2.0 with no observable external Plugin adoption (no issue
  tracker references, no community plugins under `MyOrg.Plugins.*`), and a
  multi-release deprecation window forces the framework to carry the parallel
  persistence vocabulary and classifier branch through the deprecation period
  for no proven benefit. A clean v3.0.0 break with a documented one-line
  migration is honest.

- **Lift Plugin's mount-layer features into Slice and deprecate Plugin as
  redundant.** `as:` aliasing, `route_prefix`, otp_app config merge, runtime
  `requires:` validation move to Slice; Plugin becomes a no-op alias. Rejected:
  those features have no production callers, so lifting them into Slice would
  propagate dead machinery into the surviving abstraction. If any feature later
  proves desirable, lift it then — driven by a real caller, not a hypothetical
  one.

- **Backward-compat shim: `Jido.Plugin` becomes `use Jido.Slice` +
  `@behaviour Jido.Middleware`.** Soft break for external users. Rejected for
  the reasons in Consequences: long-tail dual-shape support cost without real
  benefit; the migration is mechanical enough that the shim's value over a clean
  break is small.
