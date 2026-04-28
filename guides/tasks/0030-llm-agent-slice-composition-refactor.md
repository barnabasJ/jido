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

{:ok, pid}        = Jido.AgentServer.start_link(agent_module: MyApp.SupportAgent)
{:ok, text}       = Jido.AI.ask_sync(pid, "Refund order 42, the customer asked.")
{:ok, request_id} = Jido.AI.ask(pid, "Where is order 42?")  # fire-and-forget
```

No `Jido.AI.Agent` macro. No `Jido.AI.ReAct.run/2`. No `Jido.AI.Request{}`
struct. No `Jido.AI.await/2`. No `path:`/`schema:`/`signal_routes:`
mentioning AI on the agent module. No placeholder `model:`.

## Files to delete

- `lib/jido/ai/agent.ex` — the `Jido.AI.Agent` macro.
- `lib/jido/ai/react.ex` — the standalone synchronous runner (and its
  `Result` struct).
- `lib/jido/ai/request.ex` — the `Request{}` handle existed solely to
  carry a `sub_ref` between `ask/3` and `await/2`. With subscriptions
  pushed out of band, neither survives.
- `test/jido/ai/agent_test.exs` — tests covered the deleted macro.
- `test/jido/ai/react_test.exs` — Mimic-stubbed tests for the deleted runner.

## Files to create

### `lib/jido/ai.ex`

Namespace module. Two functions, no `Request{}` struct, no `await/2`. None
are tied to a specific agent module — they work against any `pid` whose
agent has the `Jido.AI.ReAct` slice attached.

```elixir
defmodule Jido.AI do
  @spec ask(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def ask(pid, query, opts \\ [])

  @spec ask_sync(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def ask_sync(pid, query, opts \\ [])
end
```

Implementation notes:

- `ask/3` reads no slice state. It mints a `request_id`, builds the
  `"ai.react.ask"` signal carrying per-call opts verbatim (nil where
  absent), and synchronously delivers it via `Jido.AgentServer.call/4`
  with a stub selector that returns the `request_id` on success.
- The `Jido.AI.Actions.Ask` action is the single source of truth for
  run-config resolution: per-call → slice fallback for `model`,
  `tools`, `system_prompt`, `max_iterations`; `Keyword.merge`
  per-call `:llm_opts` over the slice's stored `:llm_opts`.
- The action returns `{:error, :busy}` when the slice is `:running`,
  `{:error, :no_model}` when no model is available anywhere. `call/4`'s
  chain-error path delivers those rejections back to `ask/3` wrapped in
  `%Jido.Error.ExecutionError{}`; the rejection reason is surfaced via
  `details.reason`.
- `ask_sync/3` is the convenience for "give me the answer." It
  subscribes for the slice's terminal `:completed` / `:failed`
  transition pre-cast (ADR 0021), launches via `ask/3`, `receive`s the
  subscription fire, and returns `{:ok, text}` / `{:error, reason}` /
  `{:error, :timeout}`.
- Subscriptions are out of band by design. Callers who want richer
  observation — tool-call notifications, intermediate state, streaming
  tokens — set up their own subscription via `Jido.AgentServer.subscribe/4`
  with whatever filter they need before calling `ask/3`.

### `test/jido/ai_test.exs`

Unit tests for the namespace functions:

1. Slice config flows through to ReqLLM (model, system prompt, folded
   `max_tokens` / `temperature` in `:llm_opts`).
2. `ask_sync/3` returns the text on a single-turn happy path.
3. `ask/3` fire-and-forget returns `{:ok, request_id}`.
4. Out-of-band subscription (Mimic-stubbed) observes every intermediate
   signal in a tool-using run.
5. Per-call `:model` / `:tools` / `:system_prompt` overrides on top of
   slice defaults.
6. Per-slice and per-call `:api_key` propagation through `:llm_opts`
   (multi-tenant pattern).
7. `:busy` chain error when a run is in flight (second `Jido.AI.ask/3`
   while the first is `:running`).
8. `ask_sync/3` returns `{:error, :timeout}` when no terminal signal
   arrives.
9. Stale `tool.completed` (different `request_id`) ignored.
10. LLM error settles `:failed`; `ask_sync/3` returns `{:error, reason}`.
11. Cycle warning prepended when two consecutive tool batches match.
12. `:no_model` chain error when neither slice config nor opts supply
    a model.

These run against generic `use Jido.Agent, slices: [...]` test agents
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
llm_opts = Keyword.merge(slice.llm_opts || [], data.llm_opts || [])
```

`:llm_opts` is keyword-merged (per-call over slice defaults), not
replaced — so per-call `[max_tokens: 999]` preserves the slice's
`temperature` instead of dropping it. This is also the channel for
per-call `:api_key` (multi-tenant pattern; ReqLLM treats per-request
`:api_key` as the highest-precedence source).

Reject runs with `model == nil` (`{:error, :no_model}`).

### `lib/jido/ai/actions/{llm_turn,tool_result,failed}.ex`

Replace `alias Jido.AI.Slice` with `alias Jido.AI.ReAct, as: Slice`, OR
inline the module name. The `cycle_warning/0` and `tool_call_signature/1`
helpers move to `Jido.AI.ReAct` along with the rename.

### `mix.exs`

Update the "Jido AI" group: drop `Jido.AI.Agent`, `Jido.AI.ReAct.Result`,
`Jido.AI.Slice`, `Jido.AI.Request` (no longer exists — `ask/3` returns
just the request_id string). Add `Jido.AI` and `Jido.AI.ReAct`. Keep
`Jido.AI.ToolAdapter`, `Jido.AI.Turn`, plus the
`~r/Jido\.AI\.Actions\..*/` and `~r/Jido\.AI\.Directive\..*/` regexes.

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
- ADR 0021 conformance: `Jido.AI.ask_sync/3`'s internal subscription
  `receive`s; no polling. `ask/3` does not poll either — it makes a
  single synchronous `Jido.AgentServer.call/4` and returns. Out-of-band
  consumers subscribe via `Jido.AgentServer.subscribe/4`.

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
