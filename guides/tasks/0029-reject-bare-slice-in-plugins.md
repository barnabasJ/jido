---
name: Task 0029 — Reject bare slices in `plugins:` at compile time
description: A plugin is a Slice + Middleware. Today the agent's plugin validation only checks `function_exported?(mod, :plugin_spec, 1)`, which `use Jido.Slice` already provides — so a bare slice silently passes and gets attached. The check should fail at compile time and force `use Jido.Plugin`.
---

# Task 0029 — Reject bare slices in `plugins:` at compile time

- Implements: closes a gap in the contract `lib/jido/plugin.ex` documents — "A Plugin is a composable capability — `Jido.Slice` + `Jido.Middleware` in one module."
- Depends on: nothing.
- Blocks: nothing.
- Leaves tree: **green**.

## Context

`lib/jido/plugin.ex` defines `Jido.Plugin` as `Jido.Slice + Jido.Middleware`. `use Jido.Plugin` expands to `use Jido.Slice` + `use Jido.Middleware`. A *bare* `use Jido.Slice` is a slice, not a plugin — by the contract that file declares, it is missing the middleware half and therefore cannot be a `plugins:` entry.

The validation in `lib/jido/agent.ex:1264` only checks one function:

```elixir
defp __validate_plugin_behaviour__(mod) do
  unless function_exported?(mod, :plugin_spec, 1) do
    raise CompileError,
      description: "#{inspect(mod)} does not implement Jido.Plugin (missing plugin_spec/1)"
  end
end
```

`use Jido.Slice` already generates `plugin_spec/1` (see `lib/jido/slice.ex:268-284`). So a bare slice silently satisfies this check and gets attached as if it were a plugin. The result has surprising holes — the slice's middleware half does not exist, so anything in the agent that walks plugin middleware (the chain composition in `lib/jido/agent_server.ex:plugin_middleware_halves/1` is empty today but is the documented extension point) gets nothing from this "plugin." The error message — *"does not implement Jido.Plugin (missing plugin_spec/1)"* — also misleads when the missing piece is actually the middleware behaviour, not the spec.

This was caught while implementing task 0023: an early version of `Jido.AI.Agent` had `plugins: [Jido.AI.Slice]`, compiled clean, and ran. The user pointed out that the framework should not have allowed it.

## Goal

`use Jido.Agent, ..., plugins: [SomeBareSlice]` raises a `CompileError` at the agent module's compile time, with a message that names the slice and tells the developer to either switch to `use Jido.Plugin` or pull metadata directly (the v1 `Jido.AI.Agent` pattern: `path: SomeSlice.path(), schema: SomeSlice.schema(), signal_routes: SomeSlice.signal_routes()`).

`use Jido.Agent, ..., plugins: [SomePlugin]` (where `SomePlugin` does `use Jido.Plugin`) is unaffected.

## Approach

Two viable shapes; pick one based on existing conventions in the repo.

### Option A — Marker function on `use Jido.Plugin`

Have `Jido.Plugin.__using__/1` inject a marker function the slice macro does not:

```elixir
defmacro __using__(opts) do
  quote do
    use Jido.Slice, unquote(opts)
    use Jido.Middleware

    @doc false
    def __jido_plugin__, do: true
  end
end
```

Update `__validate_plugin_behaviour__/1`:

```elixir
defp __validate_plugin_behaviour__(mod) do
  cond do
    not function_exported?(mod, :plugin_spec, 1) ->
      raise CompileError,
        description:
          "#{inspect(mod)} does not implement Jido.Plugin — `use Jido.Plugin` " <>
            "(or attach via signal_routes:/schema: if you only need the slice surface)"

    not function_exported?(mod, :__jido_plugin__, 0) ->
      raise CompileError,
        description:
          "#{inspect(mod)} is a Slice, not a Plugin. A plugin is a Slice + Middleware. " <>
            "Either: (1) change `use Jido.Slice` to `use Jido.Plugin`, or (2) consume " <>
            "the slice's metadata directly with `path:`, `schema:`, `signal_routes:` on " <>
            "`use Jido.Agent`, and drop it from `plugins:`."

    true ->
      :ok
  end
end
```

Trade-off: marker function is a tiny convention; cheap to add; explicit.

### Option B — Behaviour check via `__behaviours__`

Inspect `mod.module_info(:attributes)[:behaviour]` (or `:behaviours`) for both `Jido.Slice` and `Jido.Middleware`. `use Jido.Middleware` already does `@behaviour Jido.Middleware`; `use Jido.Slice` does not register a behaviour today (it has no callbacks), so this would also require `use Jido.Slice` to register `@behaviour Jido.Slice` — which means defining `Jido.Slice` as a behaviour.

Trade-off: more "BEAM-native" but requires adding a `Jido.Slice` behaviour just for this check, which inflates the surface area for one validation.

**Recommendation:** Option A. Smaller diff, clearer error message, no spurious behaviour declarations.

## Files to modify

- `lib/jido/plugin.ex` — inject the `__jido_plugin__/0` marker (Option A) or add a behaviour check (Option B).
- `lib/jido/agent.ex` — update `__validate_plugin_behaviour__/1` to require both `plugin_spec/1` and the plugin marker, with a message that distinguishes "not a Jido.Plugin at all" from "is only a Slice."

## Files to create

- `test/jido/agent/plugin_validation_test.exs` — at minimum:
  - A bare `use Jido.Slice` in `plugins:` raises a `CompileError` whose message names the module and mentions both remedies (switch to `use Jido.Plugin`, or attach metadata directly).
  - A `use Jido.Plugin` module in `plugins:` compiles fine.
  - A non-module / undefined module in `plugins:` raises (existing behaviour — regression guard).

## Acceptance

- `mix compile --warnings-as-errors` clean on a tree with a hand-rolled fixture that does `use Jido.Plugin` (compiles), and a fixture that does `use Jido.Slice` and is listed in `plugins:` (raises with the new message).
- `mix test` clean. The `Jido.AI.Agent` v1 macro is already correct (it consumes `Jido.AI.Slice`'s metadata via `path:` / `schema:` / `signal_routes:` rather than mounting the slice as a plugin) — no AI-side changes needed.
- `mix dialyzer` clean (allowing the pre-existing `LLMDB.Model.t/0` warning).
- `mix credo --strict` clean.
- `mix format --check-formatted` clean.

## Out of scope

- Changing `Jido.Slice` to declare itself as a behaviour. If the project ends up wanting that for other reasons, it's a separate task.
- Backporting / migrating any in-tree slice that's currently (incorrectly) mounted in `plugins:`. A grep over `lib/` should confirm none exists; default plugins (`Jido.Identity.Plugin`, `Jido.Memory.Plugin`, `Jido.Thread.Plugin`) all already `use Jido.Plugin`.
- Reworking the error text for any other plugin-validation failure path beyond the new "is only a Slice" branch.

## Risks

- **`__behaviours__` reflection on protocols.** N/A under Option A; only relevant if Option B is chosen and `Jido.Slice` becomes a behaviour.
- **External users of `use Jido.Slice` who relied on the silent-pass behaviour.** Compile-time failure is loud and the message tells them exactly what to change. The contract was always "plugin = slice + middleware"; this commit just enforces it.
