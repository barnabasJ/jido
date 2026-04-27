---
name: Task 0021 — Add `req_llm` dep + port `Jido.AI.ToolAdapter` + port `Jido.AI.Turn`
description: Bring `req_llm` in as a runtime dep and port the two leaf modules from `jido_ai` that don't depend on the rest of the LLM subsystem — `ToolAdapter` (action → ReqLLM.Tool) and `Turn` (ReqLLM.Response → normalized projection). Both ship verbatim or near-verbatim. Foundation commit for ADR 0022.
---

# Task 0021 — Add `req_llm` dep + port `Jido.AI.ToolAdapter` + port `Jido.AI.Turn`

- Implements: [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §2, §4.
- Depends on: nothing (purely additive; new namespace).
- Blocks: [task 0022](0022-react-runtime-pure.md), [task 0023](0023-llm-agent-slice-plugin.md).
- Leaves tree: **green**.

## Goal

Bring the foundation pieces in. After this commit:

- `req_llm` is a direct runtime dep of `jido`.
- `Jido.AI.ToolAdapter` converts a list of `Jido.Action` modules into a list
  of `ReqLLM.Tool` structs (and back, via the action lookup map).
- `Jido.AI.Turn` projects a `ReqLLM.Response` into the
  `:tool_calls`-vs-`:final_answer` shape the ReAct loop consumes.

These two modules are leaves: neither calls into anything else under
`Jido.AI.*`, so they're trivially testable on their own. The downstream
ReAct loop (task 0022) and agent envelope (task 0023) build on them.

Both modules **port from `jido_ai`** rather than being designed from
scratch. The reference paths in the source tree are listed under "Files
to create" below; treat each port as "copy + minimal trim". Don't redesign.

## Files to modify

### `mix.exs`

Add `:req_llm` to the runtime deps list. Use the same minor version that
`jido_ai` currently pins (check
`/Users/jova/sandbox/jido_ai/mix.exs:71`):

```elixir
{:req_llm, "~> 1.9"},
```

`req_llm` brings transitive deps (`req`, `jason` — both already present in
the jido tree). Confirm `mix deps.get` lock-resolves cleanly; resolve any
conflicts conservatively (prefer the version `req_llm` wants).

Update `groups_for_modules` to add a "Jido AI" group:

```elixir
"Jido AI": [
  Jido.AI.Turn,
  Jido.AI.ToolAdapter
]
```

(Other AI modules join in tasks 0022–0024.)

### `mix.lock`

Updated by `mix deps.get`.

## Files to create

### `lib/jido/ai/turn.ex`

Port from `/Users/jova/sandbox/jido_ai/lib/jido_ai/turn.ex`. Drop the
streaming/tool-execution helpers (`execute/3`, `from_stream_chunks/1`, etc.)
and the `tool_results` field — v1 doesn't need them. Keep:

- The struct: `type`, `text`, `thinking_content`, `tool_calls`, `usage`,
  `model`, `finish_reason`, `message_metadata`.
- `from_response/2` — projects a `ReqLLM.Response` into a `Turn`. Detects
  tool calls via the response message's `tool_use` content parts and
  classifies the turn type accordingly.
- `needs_tools?/1` — true iff `type == :tool_calls` and `tool_calls != []`.

A trimmed `Jido.AI.Turn` should land at ~80-120 LOC (versus the original
~250 LOC).

```elixir
defmodule Jido.AI.Turn do
  @moduledoc """
  Normalized projection of a `ReqLLM.Response`.

  Classifies the response as either a tool-calling turn (the model wants
  the host to run one or more tools and call back) or a final-answer
  turn (the model is done). Used by the ReAct loop in `Jido.AI.ReAct`.
  """

  @type response_type :: :tool_calls | :final_answer
  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}

  @type t :: %__MODULE__{
          type: response_type(),
          text: String.t(),
          thinking_content: String.t() | nil,
          tool_calls: [tool_call()],
          usage: map() | nil,
          model: String.t() | nil,
          finish_reason: atom() | nil,
          message_metadata: map()
        }

  defstruct type: :final_answer,
            text: "",
            thinking_content: nil,
            tool_calls: [],
            usage: nil,
            model: nil,
            finish_reason: nil,
            message_metadata: %{}

  @spec from_response(ReqLLM.Response.t() | t(), keyword()) :: t()
  def from_response(response, opts \\ []), do: # ... (port logic)

  @spec needs_tools?(t()) :: boolean()
  def needs_tools?(%__MODULE__{type: :tool_calls, tool_calls: [_ | _]}), do: true
  def needs_tools?(%__MODULE__{}), do: false
end
```

### `lib/jido/ai/tool_adapter.ex`

Port from
`/Users/jova/sandbox/jido_ai/lib/jido_ai/tool_adapter.ex` **verbatim**, with
two trims:

1. Drop the `function_exported?(ActionSchema, :to_json_schema, 2)` /
   `function_exported?(ActionSchema, :to_json_schema, 1)` back-compat
   branches in `action_schema_to_json_schema/1`. This jido tree has the
   post-task-0000 unified action surface, so call
   `Jido.Action.Schema.to_json_schema(schema, strict: true)` directly.

2. Drop `infer_strict?/1`'s `function_exported?` probe if every action
   in this codebase exports `strict?/0` consistently (it doesn't; keep the
   probe).

Port the rest as-is: `from_actions/2`, `from_action/2`, `to_action_map/1`,
`lookup_action/3`, `validate_actions/1`, the JSON-Schema sanitization
chain. The existing tests in
`/Users/jova/sandbox/jido_ai/test/jido_ai/tool_adapter_test.exs` are the
reference fixture set; port those too.

The output shape is `[ReqLLM.Tool.t()]` — direct ReqLLM types, no wrapper.

### `test/jido/ai/turn_test.exs`

Cover:

- `from_response/2` with a final-answer `ReqLLM.Response` (text content
  only) yields `type: :final_answer`, populated `text`, `tool_calls: []`.
- `from_response/2` with a tool-calling response (`tool_use` content
  parts) yields `type: :tool_calls`, populated `tool_calls`.
- `from_response/2` with mixed text + tool_use yields `type: :tool_calls`
  and preserves the leading text in `text`.
- `:model` opt overrides the model string from the response.
- `needs_tools?/1` matrix: `:final_answer` → false, `:tool_calls` with
  empty list → false, `:tool_calls` with one or more → true.

Use `ReqLLM.Response.t()` fixtures built via `ReqLLM.Response`'s public
constructors; don't hand-construct the struct. If ReqLLM doesn't expose a
test-fixture helper, use `struct/2` against the public type and document
the dependency on the struct shape.

### `test/jido/ai/tool_adapter_test.exs`

Port from
`/Users/jova/sandbox/jido_ai/test/jido_ai/tool_adapter_test.exs`. Keep the
fixture actions inline. Cases:

- `from_actions/2` produces the right number of `ReqLLM.Tool` structs.
- `from_actions/2` with `:prefix` prefixes every tool name.
- `from_actions/2` with `:filter` filters before producing.
- `from_actions/2` raises on duplicate tool names.
- `from_action/2` with `:strict` true / false / auto (via `strict?/0`).
- Strict-mode JSON Schema has `additionalProperties: false` on every
  nested object.
- Empty schema produces a valid empty-object schema, not a bare `%{}`.
- `to_action_map/1` round-trips name → module.
- `lookup_action/3` finds modules by their (prefixed) tool name.
- `validate_actions/1` returns `:ok` on valid; `{:error, ...}` on
  missing `name/0` / `description/0` / `schema/0`.

### `test/support/jido/ai/test_actions.ex`

Tiny fixture actions used by `tool_adapter_test.exs` and downstream tests:
`TestAdd`, `TestMultiply`, `TestEcho`, `TestFails`. Each is a one-screen
`use Jido.Action` declaration. Lives under `test/support/`, only compiles
in `:test` (already configured via `elixirc_paths(:test)`).

## Files to delete

None.

## Acceptance

- `mix deps.get` resolves cleanly with `req_llm` added; `mix.lock` updated.
- `mix compile --warnings-as-errors` clean.
- `mix test test/jido/ai/` passes.
- `mix dialyzer` clean (or the existing baseline holds).
- `mix credo --strict` clean.
- `mix format --check-formatted` clean.
- Public modules: `Jido.AI.Turn`, `Jido.AI.ToolAdapter`. No others under
  `Jido.AI.*` are added in this commit.
- `Jido.AI.ToolAdapter.from_actions/2` returns `[ReqLLM.Tool.t()]` (verify
  the struct types in a test).
- No references from `lib/jido/` outside `lib/jido/ai/` to the new modules
  yet — they're internal until tasks 0022-0023 wire them through.

## Out of scope

- **Conversation / Message wrappers.** v1 uses `ReqLLM.Context` and
  `ReqLLM.Message` directly. No `Jido.AI.Conversation`, no
  `Jido.AI.Message`. ADR 0022 §3.
- **Model abstraction.** v1 uses ReqLLM's spec format directly. No
  `Jido.AI.Model` behaviour.
- **ReAct loop.** Task 0022.
- **Agent envelope, slice, actions, directives, macro.** Task 0023.
- **Streaming.** v1 is generate-only. `Turn.from_response/2` only handles
  the non-streaming `ReqLLM.Response`.
- **`tool_results` on `Turn`.** v1 doesn't carry tool results on the turn;
  they're appended to the conversation directly by the ReAct actions.

## Risks

- **JSON Schema sanitization for strict mode.** The recursive sanitizer
  needs to walk every nested object, including those inside `properties`,
  `items`, and `additionalProperties` itself. The reference logic in
  `jido_ai/lib/jido_ai/tool_adapter.ex:299-320` already handles this;
  port verbatim.
- **Empty schema edge case.** A `Jido.Action` with no `schema:` should
  produce `%{"type" => "object", "properties" => %{}, "required" => [],
  "additionalProperties" => false}`, not `%{}`. The sanitizer's
  `enforce_no_additional_properties/1 |> case do %{} -> ...` branch is
  the load-bearing piece; keep it.
- **`Jido.Action.Schema.to_json_schema` arity drift.** Confirm the current
  arity in this jido tree is `to_json_schema(schema, opts)` (the
  unified-action-surface version). If it's still `to_json_schema(schema)`
  somewhere, the port still compiles but loses strict-mode handling — pin
  the arity at port time and adjust if needed.
- **Strict-mode default.** `from_action/2` infers strict via
  `function_exported?(module, :strict?, 0)`. Existing actions in this
  codebase don't export `strict?/0`, so the default is `false`. That's
  matched by `jido_ai`'s behaviour. If a later task wants strict-by-default
  it's a separate ADR — don't quietly flip it here.
- **`req_llm` minor-version alignment.** Pin to the same minor that
  `jido_ai` is currently using to keep the port surface predictable. If
  jido picks up a newer `req_llm` later, that's a version-bump task with
  its own scope.
