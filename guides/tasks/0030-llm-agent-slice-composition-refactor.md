---
name: Task 0030 — Refactor LLM agent: ReAct attached via `slices:` to a regular `Jido.Agent`
description: With task 0032 in place, `Jido.AI.ReAct` becomes a `use Jido.Slice` module with a `config_schema` declaring `:model`, `:tools`, `:system_prompt`, `:max_iterations`, `:max_tokens`, `:temperature`, and `:llm_opts`. Users compose it via `use Jido.Agent, slices: [{Jido.AI.ReAct, model: ..., tools: ...}]`. The `Jido.AI.Agent` macro is deleted; user-facing API moves to `Jido.AI.{ask,await,ask_sync}/N`. The standalone `Jido.AI.ReAct.run/2` synchronous runner retires — the slice is the only ReAct.
---

# Task 0030 — Refactor LLM agent: ReAct attached via `slices:` to a regular `Jido.Agent`

- Implements: [ADR 0022 v3](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §6, §7, and the `ReAct.run/2` retirement in *Consequences*.
- Depends on: [task 0032](0032-framework-slices-attachment-option.md) (the `slices:` option must exist before this task can use it), [task 0023](0023-llm-agent-slice-plugin.md) (provides the slice / actions / directives we keep).
- Supersedes the user-facing surface of: task 0022 (`Jido.AI.ReAct.run/2`), task 0023 (`use Jido.AI.Agent` macro).
- Blocks: [task 0031](0031-llm-agent-livebook-and-tagged-integration-tests.md).
- Leaves tree: **green**.

## Context

Task 0023 shipped a `use Jido.AI.Agent` macro that carried LLM config on the
agent module. ADR 0022 v2 walked that back to "the slice is the agent's own
slice"; v3 walks it back further: the slice is its own thing, attached via
the new `slices:` option from task 0032. The agent module is fully generic —
it declares no `path`, no `schema`, no `signal_routes` related to the AI
slice. The slice carries all of that internally and the framework wires it
in.

The standalone synchronous `Jido.AI.ReAct.run/2` runner from task 0022 has
zero callers in `lib/` after task 0023's signal-driven loop. Two parallel
implementations of "the loop" violates "no dead code"; the slice is the only
ReAct in v3.

## Goal

After this commit, an LLM agent looks like this — and only this:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent,
    name: "support",
    slices: [
      {Jido.AI.ReAct,
        model: "anthropic:claude-haiku-4-5-20251001",
        tools: [MyApp.Actions.LookupOrder, MyApp.Actions.RefundOrder],
        system_prompt: "You are a support agent.",
        max_iterations: 5}
    ]
end

{:ok, pid}     = Jido.AgentServer.start_link(agent_module: MyApp.SupportAgent)
{:ok, request} = Jido.AI.ask(pid, "Where is order 42?")
{:ok, text}    = Jido.AI.await(request, timeout: 30_000)
```

No `Jido.AI.Agent` macro. No `Jido.AI.ReAct.run/2`. No `path:`/`schema:`/
`signal_routes:` mentioning AI on the agent module. No placeholder `model:`.

## Files to delete

- `lib/jido/ai/agent.ex` — the `Jido.AI.Agent` macro.
- `lib/jido/ai/react.ex` — the standalone synchronous runner (and its
  `Result` struct).
- `test/jido/ai/agent_test.exs` — tests covered the deleted macro.
- `test/jido/ai/react_test.exs` — Mimic-stubbed tests for the deleted runner.
- `test/jido/ai/react_e2e_test.exs` — integration tests for the deleted
  runner. Agent-level e2e coverage is task 0031.

## Files to create

### `lib/jido/ai.ex`

Namespace module. None of these are tied to a specific agent module — they
work against any `pid` whose agent has the `Jido.AI.ReAct` slice attached.

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

- One `state/3` projection reads the slice at `:ai` once, returning both the
  busy guard and the run-config defaults: `{status, %{model:, tools:,
  system_prompt:, max_iterations:, llm_opts:}}`. If `status == :running`,
  return `{:error, :busy}`. Otherwise resolve per-call opts on top of the
  slice defaults; if `:model` is still nil, return `{:error, :no_model}`.
- `ask/3` mints `request_id`, registers `subscribe/4` for the slice's
  terminal transition (pre-cast, ADR 0021), then casts `ai.react.ask`.
- `await/2` `receive`s the subscription fire. Pure receive; no polling.
- `ask_sync/3` pipes the two together.

### `test/jido/ai_test.exs`

Unit tests for the namespace functions, mirroring the cases the deleted
`agent_test.exs` covered:

1. `ask/3` happy path against a Mimic-stubbed `ReqLLM.Generation.generate_text/3`.
2. `ask_sync/3` returns the text.
3. Per-call `:model` / `:tools` / `:system_prompt` overrides on top of slice
   defaults.
4. `:busy` short-circuit while a run is `:running`.
5. `:timeout` from `await/2` when no terminal signal arrives.
6. Stale `tool.completed` (different `request_id`) ignored.
7. LLM error settles `:failed`; `await/2` returns `{:error, reason}`.
8. Cycle warning prepended when two consecutive tool batches match.
9. `{:error, :no_model}` when neither slice defaults nor per-call opts supply a model.

These run against a generic `use Jido.Agent, slices: [...]` test agent
defined inside the test module — no AI-specific macro.

## Files to modify

### `lib/jido/ai/slice.ex` → `lib/jido/ai/re_act.ex`

Rename the module to `Jido.AI.ReAct` and rewrite as a `use Jido.Slice` with
a real `config_schema/0`:

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
    ],
    schema:
      Zoi.object(%{
        status: Zoi.atom() |> Zoi.default(:idle),
        request_id: Zoi.any() |> Zoi.default(nil),
        context: Zoi.any() |> Zoi.default(nil),
        iteration: Zoi.integer() |> Zoi.default(0),
        max_iterations: Zoi.integer() |> Zoi.default(10),
        result: Zoi.any() |> Zoi.default(nil),
        error: Zoi.any() |> Zoi.default(nil),
        pending_tool_calls: Zoi.list(Zoi.any()) |> Zoi.default([]),
        tool_results_received: Zoi.list(Zoi.any()) |> Zoi.default([]),
        previous_tool_signature: Zoi.any() |> Zoi.default(nil),
        model: Zoi.any() |> Zoi.default(nil),
        tools: Zoi.list(Zoi.atom()) |> Zoi.default([]),
        system_prompt: Zoi.any() |> Zoi.default(nil),
        llm_opts: Zoi.any() |> Zoi.default([])
      }, coerce: true),
    config_schema:
      Zoi.object(%{
        model: Zoi.any() |> Zoi.optional(),
        tools: Zoi.list(Zoi.atom()) |> Zoi.default([]),
        system_prompt: Zoi.any() |> Zoi.optional(),
        max_iterations: Zoi.integer() |> Zoi.default(10),
        max_tokens: Zoi.integer() |> Zoi.default(4096),
        temperature: Zoi.any() |> Zoi.default(0.2),
        llm_opts: Zoi.any() |> Zoi.default([])
      }, coerce: true)
end
```

The framework's `slices:` machinery (task 0032) validates the user's config
through `config_schema/0`, then merges those values into the slice's initial
state under the keys the schema declares. So the slice is born with `status:
:idle`, `model:` from the user's config, etc.

Add `system_prompt` to the slice state (was per-signal-only in task 0023);
the `Ask` action falls back to the slice's `system_prompt` when signal data
omits it.

### `lib/jido/ai/actions/ask.ex`

Make signal data fields optional (except `query` and `request_id`). Fall back
to slice state for run config:

```elixir
schema: [
  query: [type: :string, required: true],
  request_id: [type: :string, required: true],
  model: [type: :any, default: nil],
  tools: [type: {:or, [{:list, :atom}, nil]}, default: nil],
  system_prompt: [type: {:or, [:string, nil]}, default: nil],
  max_iterations: [type: {:or, [:pos_integer, nil]}, default: nil],
  llm_opts: [type: {:or, [:keyword_list, nil]}, default: nil]
]
```

In `run/4`, resolve per-call → slice fallback:

```elixir
model = data.model || slice.model
tools = if is_nil(data.tools), do: slice.tools || [], else: data.tools
system_prompt = data.system_prompt || slice.system_prompt
max_iter = data.max_iterations || slice.max_iterations
llm_opts = data.llm_opts || slice.llm_opts || []
```

Reject runs with `model == nil` (`{:error, :no_model}`).

### `lib/jido/ai/actions/{llm_turn,tool_result,failed}.ex`

Replace `alias Jido.AI.Slice` with `alias Jido.AI.ReAct, as: Slice`, OR
inline the module name. The `cycle_warning/0` and `tool_call_signature/1`
helpers move to `Jido.AI.ReAct` along with the rename.

### `mix.exs`

Update the "Jido AI" group: drop `Jido.AI.Agent`, `Jido.AI.ReAct.Result`,
`Jido.AI.Slice`. Add `Jido.AI` and `Jido.AI.ReAct`. Keep `Jido.AI.Request`,
`Jido.AI.ToolAdapter`, `Jido.AI.Turn`, plus the `~r/Jido\.AI\.Actions\..*/`
and `~r/Jido\.AI\.Directive\..*/` regexes.

### `lib/jido/ai/turn.ex` moduledoc

Replace "Used by the ReAct loop in `Jido.AI.ReAct`" (referring to the deleted
synchronous runner) with "Consumed by `Jido.AI.Actions.LLMTurn` after
`Jido.AI.Directive.LLMCall`'s executor packages a `ReqLLM.Response`."

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean (allowing the pre-existing `LLMDB.Model.t/0` warning).
- `mix test` clean — zero `warning:` lines.
- `mix test --include e2e` clean — zero `warning:` lines (this dev machine
  has LM Studio + a compatible model loaded; e2e is part of the gate).
- The example agent in this task's docstring (`MyApp.SupportAgent`) compiles
  and runs end-to-end against a Mimic-stubbed `ReqLLM.Generation`.
- ADR 0022 v3 §6 conformance: no `Jido.AI.Agent` macro, no `Jido.AI.ReAct.run/2`,
  no `Jido.AI.Slice` module name. The user agent module declares **only**
  `name:` and `slices: [{Jido.AI.ReAct, ...config...}]`. No `path:` / `schema:`
  / `signal_routes:` mentioning anything AI-related.
- ADR 0019 conformance: every action returns `{:ok, slice, [directive]}` or
  `{:error, reason}`. Directive executors emit signals; never return state.
- ADR 0021 conformance: `Jido.AI.await/2` `receive`s; no polling.

## Out of scope

- Streaming, checkpoint resume, multi-run concurrency.
- Migration guide from v1 macro to v3 composition. The v1 commit is `4f4532e`;
  the diff is available there.
- Multi-instance ReAct slice (`{Jido.AI.ReAct, as: :customer, model: ...},
  {Jido.AI.ReAct, as: :sales, model: ...}` on the same agent). Task 0032
  reserves the `:as` field but does not wire multi-instance for v1.
- A separate sync-LLM-call livebook. The agent path is the one path; one-off
  use is `Jido.AI.ask_sync/3` against a quickly-spun-up agent server.

## Risks

- **Order of work.** This task depends on task 0032 (`slices:` framework
  option) and task 0029 (rejecting bare slices in `plugins:`). 0032 must land
  first; 0029 can land before or alongside 0030.

- **`Jido.AI.ReAct.config_schema/0` validation timing.** The framework's
  `slices:` machinery validates the supplied config at the agent module's
  compile time (when `use Jido.Agent` runs). A typo in `tools:` (e.g., a
  missing module reference) raises CompileError there, not at runtime —
  good. Make sure the error message names the slice and the config key.

- **Required `:model` validation.** v3 makes `:model` optional in
  `config_schema:` so an agent can be defined without baking a model in (the
  caller supplies it per-call). The action's runtime check
  (`{:error, :no_model}`) is the floor. Test this case.

- **Slice rename `Jido.AI.Slice` → `Jido.AI.ReAct`.** The actions reference
  the slice's helpers (`cycle_warning/0`, `tool_call_signature/1`). Move those
  to the renamed module. Catch every reference in `lib/`, `test/`, and
  `guides/`.

- **`Jido.AI.ReAct.run/2`'s docs.** `lib/jido/ai/turn.ex` had a back-reference;
  task 0023's slice doc referenced "the synchronous loop." Catch every
  reference and either remove or repoint; otherwise `mix docs` emits broken
  xref warnings.
