---
name: Task 0030 — Refactor LLM agent: ReAct as a configured slice on a regular `Jido.Agent`
description: Replace the `use Jido.AI.Agent` macro (task 0023) with a slice-composition design. `Jido.AI.ReAct` is a slice exposing `schema/1` (accepting LLM config opts) and `signal_routes/0`; users wire it into a regular `use Jido.Agent` directly. User-facing API moves to `Jido.AI.ask/3`, `Jido.AI.await/2`, `Jido.AI.ask_sync/3`. Retire the standalone synchronous `Jido.AI.ReAct.run/2` runner (task 0022). Supersedes the user-facing surface from task 0023.
---

# Task 0030 — Refactor LLM agent: ReAct as a configured slice on a regular `Jido.Agent`

- Implements: [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) v2 §6, §7, and the `ReAct.run/2` retirement in *Consequences*.
- Depends on: [task 0023](0023-llm-agent-slice-plugin.md) (provides the slice / actions / directives we keep), [task 0029](0029-reject-bare-slice-in-plugins.md) (frames why slices are not plugins).
- Supersedes the user-facing surface of: task 0022 (`Jido.AI.ReAct.run/2`), task 0023 (`use Jido.AI.Agent` macro).
- Blocks: [task 0031](0031-llm-agent-livebook-and-tagged-integration-tests.md).
- Leaves tree: **green**.

## Context

Task 0023 shipped `Jido.AI.Agent` — a `use Jido.AI.Agent` macro that owned the
slice path, schema, signal routes, AND LLM config (`model:`, `tools:`,
`system_prompt:`, `max_iterations:`) at compile time. Two problems became
apparent during implementation:

1. **The agent module ended up knowing about LLM concerns.** A generic agent
   doesn't know what a "model" or a "tool" is; it knows `path:`, `schema:`,
   `signal_routes:`. The `Jido.AI.Agent` macro forced model/tools/system_prompt
   onto the agent surface and required a placeholder `model:` value to
   instantiate the struct so the user could override per-call. That's a code
   smell.

2. **The slice ended up not being configurable as a slice.** Per ADR 0017 the
   slice owns its routes, schema, and actions. But the LLM config (model,
   tools, system_prompt) is run-config the slice needs — and the v1 design
   pulled it onto the agent macro instead of letting it flow through the slice's
   own `schema/1` defaults. The slice was the agent's own slice in name only.

Task 0022 also shipped a standalone synchronous runner `Jido.AI.ReAct.run/2`
that the agent envelope was originally going to wrap from inside a Task. The
final task-0023 implementation drives the loop signal-driven directly through
the slice's actions and the LLMCall/ToolExec directives, so `ReAct.run/2` has
zero callers in `lib/`. Two parallel implementations of "the loop" violates
"no dead code"; the slice is the only ReAct.

ADR 0022 v2 codifies the new shape (§6 slice composition, §7 namespace helpers,
no `ReAct.run/2`). This task implements it.

## Goal

After this commit, an LLM agent is composed like this:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent,
    name: "support",
    path: :ai,
    schema:
      Jido.AI.ReAct.schema(
        model: "anthropic:claude-haiku-4-5-20251001",
        tools: [MyApp.Actions.LookupOrder, MyApp.Actions.RefundOrder],
        system_prompt: "You are a support agent.",
        max_iterations: 5
      ),
    signal_routes: Jido.AI.ReAct.signal_routes()
end

{:ok, pid}     = Jido.AgentServer.start_link(agent_module: MyApp.SupportAgent)
{:ok, request} = Jido.AI.ask(pid, "Where is order 42?")
{:ok, text}    = Jido.AI.await(request, timeout: 30_000)
```

No `Jido.AI.Agent` macro. No placeholder `model:`. No `ReAct.run/2`.

## Files to delete

- `lib/jido/ai/agent.ex` — the `Jido.AI.Agent` macro is gone.
- `lib/jido/ai/react.ex` — the standalone synchronous runner is gone (its
  `Result` struct goes with it).
- `test/jido/ai/agent_test.exs` — its tests cover the deleted macro.
- `test/jido/ai/react_test.exs` — Mimic-stubbed tests for the deleted runner.
- `test/jido/ai/react_e2e_test.exs` — integration tests for the deleted runner.
  The `:e2e` coverage moves to task 0031's agent-level integration tests.

## Files to create

### `lib/jido/ai.ex`

Namespace module exposing the user-facing functions. None of these are tied to
a specific agent module — they work against any `pid` whose agent has the
ReAct slice mounted at `:ai`.

```elixir
defmodule Jido.AI do
  @spec ask(GenServer.server(), String.t(), keyword()) ::
          {:ok, Jido.AI.Request.t()} | {:error, term()}
  def ask(pid, query, opts \\ [])

  @spec await(Jido.AI.Request.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def await(request, opts \\ [])

  @spec ask_sync(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def ask_sync(pid, query, opts \\ [])
end
```

Implementation notes:

- `ask/3` reads `s.agent.state.ai` for the slice's run-config defaults
  (`model`, `tools`, `system_prompt`, `max_iterations`, `llm_opts`). Per-call
  opts override per call. Required keys missing from BOTH the slice state and
  the per-call opts (notably `:model` if the slice was constructed without one)
  return `{:error, :no_model}` rather than crashing.
- `ask/3` mints `request_id`, registers a `subscribe/4` for the slice's
  terminal transition (pre-cast — ADR 0021), then casts `ai.react.ask`. Returns
  `{:ok, %Jido.AI.Request{}}`.
- `await/2` `receive`s the subscription fire. Returns `{:ok, text}` /
  `{:error, reason}` / `{:error, :timeout}`. Pure `receive` — no polling.
- `ask_sync/3` pipes the two together.
- The single-active-run guard (`{:error, :busy}`) is a `state/3` projection
  read against `s.agent.state.ai.status` *before* the cast. Same shape as the
  current `Jido.AI.Agent.__ask__/4`; lift the helper into `Jido.AI` and drop
  the macro.

### `test/jido/ai_test.exs`

Unit tests for the namespace functions. Mirror the cases from the deleted
`test/jido/ai/agent_test.exs`:

1. `ask/3` happy path — reads slice defaults, casts `ai.react.ask`, subscription
   fires on the terminal transition, `await/2` returns the text.
2. `ask_sync/3` pipes the two together.
3. Per-call override of `:model`, `:tools`, `:system_prompt` overrides slice
   defaults for that one call.
4. `:busy` short-circuit while a run is `:running`.
5. `await/2` `:timeout` when no terminal signal arrives.
6. Stale `tool.completed` (different `request_id`) is ignored.
7. LLM error settles `:failed`, `await/2` returns `{:error, reason}`.
8. Cycle warning prepended on a repeated tool batch (integration through the
   real signal pipeline; Mimic-stubs `ReqLLM.Generation.generate_text/3` for
   three turns).

These run against a generic `use Jido.Agent` test agent defined inside the
test module — no AI-specific macro.

## Files to modify

### `lib/jido/ai/slice.ex` → `lib/jido/ai/re_act.ex`

Rename the module to `Jido.AI.ReAct` and rewrite the schema as a
configurable function:

```elixir
defmodule Jido.AI.ReAct do
  use Jido.Slice,
    name: "ai",
    path: :ai,
    actions: [
      Jido.AI.Actions.Ask,
      Jido.AI.Actions.LLMTurn,
      Jido.AI.Actions.ToolResult,
      Jido.AI.Actions.Failed
    ],
    signal_routes: [
      {"ai.react.ask", Jido.AI.Actions.Ask},
      {"ai.react.llm.completed", Jido.AI.Actions.LLMTurn},
      {"ai.react.tool.completed", Jido.AI.Actions.ToolResult},
      {"ai.react.failed", Jido.AI.Actions.Failed}
    ]

  # Override the macro-generated schema/0 with a parameterized schema/1.
  # The framework's `__seed_own_slice__/2` calls `validated_opts[:schema]`
  # at compile time of the using agent module — so the user passes
  # `schema: Jido.AI.ReAct.schema(model: ..., tools: ...)` and the schema
  # bakes those values in as the slice's defaults.
  @spec schema(keyword()) :: Zoi.schema()
  def schema(opts \\ []) do
    Zoi.object(%{
      status: Zoi.atom() |> Zoi.default(:idle),
      request_id: Zoi.any() |> Zoi.default(nil),
      context: Zoi.any() |> Zoi.default(nil),
      iteration: Zoi.integer() |> Zoi.default(0),
      max_iterations: Zoi.integer() |> Zoi.default(Keyword.get(opts, :max_iterations, 10)),
      result: Zoi.any() |> Zoi.default(nil),
      error: Zoi.any() |> Zoi.default(nil),
      pending_tool_calls: Zoi.list(Zoi.any()) |> Zoi.default([]),
      tool_results_received: Zoi.list(Zoi.any()) |> Zoi.default([]),
      previous_tool_signature: Zoi.any() |> Zoi.default(nil),
      model: Zoi.any() |> Zoi.default(Keyword.get(opts, :model)),
      tools: Zoi.list(Zoi.atom()) |> Zoi.default(Keyword.get(opts, :tools, [])),
      system_prompt: Zoi.any() |> Zoi.default(Keyword.get(opts, :system_prompt)),
      llm_opts: Zoi.any() |> Zoi.default(build_llm_opts(opts))
    }, coerce: true)
  end

  defp build_llm_opts(opts) do
    base = [
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      temperature: Keyword.get(opts, :temperature, 0.2)
    ]
    Keyword.merge(base, Keyword.get(opts, :llm_opts, []))
  end

  # cycle_warning/0 and tool_call_signature/1 stay as-is.
end
```

Add `system_prompt` to the slice state (was previously per-signal-only). The
`Ask` action falls back to slice state values when signal data omits a key —
that's how runtime defaults flow through.

### `lib/jido/ai/actions/ask.ex`

Make signal data fields optional, fall back to slice state for run config.
Keep `query` and `request_id` as required.

```elixir
schema: [
  query: [type: :string, required: true],
  request_id: [type: :string, required: true],
  model: [type: :any, default: nil],
  tools: [type: {:list, :atom}, default: nil],
  system_prompt: [type: {:or, [:string, nil]}, default: nil],
  max_iterations: [type: {:or, [:pos_integer, nil]}, default: nil],
  llm_opts: [type: {:or, [:keyword_list, nil]}, default: nil]
]
```

In `run/4`:

```elixir
model = data.model || slice.model
tools = if is_nil(data.tools), do: slice.tools || [], else: data.tools
system_prompt = data.system_prompt || slice.system_prompt
max_iter = data.max_iterations || slice.max_iterations
llm_opts = data.llm_opts || slice.llm_opts || []
```

Reject runs with `model == nil` (`{:error, :no_model}`) so a slice constructed
without a default model fails clearly when asked without a per-call model.

### `mix.exs`

Update the "Jido AI" group: drop `Jido.AI.Agent`, `Jido.AI.ReAct.Result`,
`Jido.AI.Slice`. Add `Jido.AI`, `Jido.AI.ReAct`. Keep `Jido.AI.Request`,
`Jido.AI.ToolAdapter`, `Jido.AI.Turn`. Keep the `~r/Jido\.AI\.Actions\..*/`
and `~r/Jido\.AI\.Directive\..*/` regexes.

### `lib/jido/ai/turn.ex` moduledoc

Replace "Used by the ReAct loop in `Jido.AI.ReAct`" (the deleted synchronous
runner) with "Consumed by `Jido.AI.Actions.LLMTurn` after
`Jido.AI.Directive.LLMCall`'s executor packages a `ReqLLM.Response`."

### `lib/jido/ai/actions/{llm_turn,tool_result,failed}.ex`

Replace any `alias Jido.AI.Slice` with `alias Jido.AI.ReAct, as: Slice`, OR
inline the module name. Same for `Slice.cycle_warning()` /
`Slice.tool_call_signature/1` — those helper functions move to
`Jido.AI.ReAct` along with the rename.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean (allowing the pre-existing `LLMDB.Model.t/0` warning).
- `mix test` passes with **zero `warning:` lines** in the output.
- `mix test --include e2e` passes (the agent-level e2e tests land in task 0031;
  this task's `:e2e` coverage is whatever already passes plus the new
  `Jido.AI`-helper Mimic tests).
- The example agent in this task's docstring (`MyApp.SupportAgent`) compiles
  and runs end-to-end against a Mimic-stubbed `ReqLLM.Generation`.
- ADR 0019 conformance: every action returns `{:ok, slice, [directive]}` or
  `{:error, reason}`. Directive executors emit signals; never return state.
- ADR 0021 conformance: `Jido.AI.await/2` `receive`s; no polling.
- ADR 0022 v2 §6 conformance: no `Jido.AI.Agent` macro, no `Jido.AI.ReAct.run/2`,
  no `Jido.AI.Slice` module name (the slice module is `Jido.AI.ReAct`).

## Files left untouched

- `lib/jido/ai/tool_adapter.ex`, `lib/jido/ai/turn.ex` (besides the moduledoc tweak),
  `lib/jido/ai/request.ex` — these are content-stable from task 0021/0023.
- `lib/jido/ai/directive/llm_call.ex`, `lib/jido/ai/directive/tool_exec.ex` —
  content-stable from task 0023; only the inline `Jido.task_supervisor_name/1`
  call stays as-is (no helper module).
- `lib/jido/ai/actions/{llm_turn,tool_result,failed}.ex` — content-stable
  apart from the `Jido.AI.Slice` → `Jido.AI.ReAct` rename and the
  `Ask` action's fallback-to-slice-state change.

## Out of scope

- Streaming, checkpoint resume, multi-run concurrency — same as ADR 0022 v1.
- A migration guide from the v1 macro to the v2 composition. The v1 commit is
  `4f4532e` on the same branch; if anyone built on it, they have the diff.
- An attachment mechanism for non-default, non-own configured slices (i.e.,
  putting the ReAct slice on an agent that already has its own non-AI slice).
  v1 keeps the slice as the agent's own.
- A second livebook for "synchronous one-off LLM calls." That use case is
  served by spinning an agent with `Jido.AgentServer.start_link` and calling
  `Jido.AI.ask_sync/3`.

## Risks

- **The slice's `schema/1` is parameterized at compile time.** Users pass
  `schema: Jido.AI.ReAct.schema(model: ...)` inside `use Jido.Agent`. The
  macro evaluates it then. `Jido.AI.ReAct` must be compiled before any user
  agent module that depends on it. Mix dependency tracking handles this — both
  files live in the same project.

- **Slice's macro-generated `schema/0` vs custom `schema/1`.** `use Jido.Slice`
  generates `schema/0` returning `@validated_opts[:schema]`. We do not pass a
  `schema:` to `use Jido.Slice` (since the schema is parameterized); the
  generated `schema/0` would return `nil`. We intentionally hide it by defining
  `schema/1` instead — users always call `Jido.AI.ReAct.schema(opts)` from
  their `use Jido.Agent`. Document this clearly in the slice's moduledoc.

- **Required `:model` validation timing.** Validating `model != nil` happens
  at the `Ask` action's `run/4` (`{:error, :no_model}`), not at compile time.
  A user who builds an agent without a `:model` and never overrides per call
  will get a clean `{:error, :no_model}` from the first `ask/3` instead of a
  cryptic ReqLLM crash later. Test this case explicitly.

- **`Jido.AI.ask/3` reads slice state before casting.** That's the single-
  active-run guard *and* the run-config defaulting. Two `state/3` reads in a
  row would be wasteful — fold both into one selector that returns `{:busy
  | :idle | :completed | :failed, defaults_map}`.

- **The deleted `Jido.AI.ReAct.run/2`'s docs.** `lib/jido/ai/turn.ex` had a
  back-reference. Catch every reference to `Jido.AI.ReAct.run/2` /
  `Jido.AI.ReAct.Result` and either remove or repoint; otherwise `mix docs`
  emits broken xref warnings.
