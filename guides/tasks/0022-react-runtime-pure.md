---
name: Task 0022 — `Jido.AI.ReAct` synchronous runner over `ReqLLM.Generation`
description: Port `jido_ai`'s ReAct loop into a synchronous, single-function entry point that takes a query, a ReqLLM model spec, and a list of action modules, and returns a result. No streaming, no checkpoints, no agent dep. Mimic-stubbed unit tests.
---

# Task 0022 — `Jido.AI.ReAct` synchronous runner over `ReqLLM.Generation`

- Implements: [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §5 (the loop logic itself; the signal-driven envelope lands in task 0023).
- Depends on: [task 0021](0021-reqllm-dep-and-tool-adapter.md).
- Blocks: [task 0023](0023-llm-agent-slice-plugin.md).
- Leaves tree: **green**.

## Goal

Ship the ReAct loop as a synchronous function. Inputs: a query string, a
ReqLLM model spec, a list of `Jido.Action` modules to expose as tools, and
options. Output: a `%Jido.AI.ReAct.Result{}` with the final text, the full
`ReqLLM.Context`, the iteration count, the termination reason, and
aggregated usage.

The loop calls `ReqLLM.Generation.generate_text/3` directly and
`Jido.Exec.run/4` directly. **Synchronous on purpose**: keeping the loop
synchronous and self-contained makes it trivially testable with Mimic,
separates loop semantics from agent-integration semantics, and produces a
useful standalone API for one-off LLM scripts that don't need a long-running
agent.

Task 0023 wraps this synchronous loop in the signal-driven
slice/plugin/directive envelope described in ADR 0022 §5. The synchronous
function survives that wrapping — it's still callable directly.

> **Note on ADR 0019 conformance.** ADR 0019 governs *agent actions*: actions
> that mutate slice state must not do side effects. `Jido.AI.ReAct.run/2`
> is not an agent action — it's a top-level function that *uses* the model
> and tools to produce a result. Calling it from inside a `Jido.Action`
> would violate ADR 0019. Task 0023's signal-driven envelope is the way
> agent code drives this loop.

## Reference port

The source is `/Users/jova/sandbox/jido_ai/lib/jido_ai/reasoning/react/runner.ex`
(1,242 LOC). v1 trims aggressively. **Drop**:

- The coordinator-task / `Stream.resource` machinery (`stream/3`,
  `stream_from_state/3`, `start_task/2`, `next_event/2`, `cleanup/2`).
- Streaming-specific code (`request_turn_stream/6`, `consume_stream/5`,
  `process_stream/2`, all heartbeat / progress logic).
- Checkpoint tokens (`emit_checkpoint/5`, `Token.*`).
- Pending-input server (`drain_pending_input/4`,
  `seal_pending_input_server/1`).
- Cancellation (`check_cancel!/2`, `announce_stream_control/3`).
- Request transformer (`maybe_transform_request/4` and the `RequestTransformer`
  module wholesale).
- Effect policy / observability emission (`emit_event/6` machinery for
  external signal emission — those re-emerge as agent-side signals in
  task 0023, not from the loop).
- The Strategy delegation glue.

**Keep** (port logic, restructure for synchronous shape):

- The `run_loop` core: turn → classify → execute tools → loop.
- The `@cycle_warning` text and the identical-call-signature detection
  (`tool_call_signature/1` and the comparison logic in lines ~200-211).
- The max-iterations cutoff.
- Tool argument coercion via `Jido.Action.Tool.convert_params_using_schema/2`.
- Tool result encoding (Jason on success, error blob on failure — pattern
  matches `Jido.Action.Tool.execute_action/3`).

The trimmed runner should land at ~250-400 LOC.

## Files to create

### `lib/jido/ai/react.ex`

```elixir
defmodule Jido.AI.ReAct do
  @moduledoc """
  Synchronous ReAct loop over `ReqLLM.Generation.generate_text/3`.

  Drives a `reason → act → observe` cycle until the model produces a
  final answer, an error occurs, or `max_iterations` is reached.

  This module is the loop logic. To run a ReAct conversation under a
  Jido agent (with signals, observability, async tool exec), use
  `use Jido.AI.Agent` (task 0023). To run one-off, call `run/2` directly.
  """

  alias Jido.AI.{Turn, ToolAdapter}
  alias ReqLLM.Context

  defmodule Result do
    @type t :: %__MODULE__{
            text: String.t() | nil,
            context: ReqLLM.Context.t(),
            iterations: non_neg_integer(),
            termination_reason: :final_answer | :max_iterations | :error,
            usage: map(),
            error: term() | nil
          }
    defstruct [:text, :context, :iterations, :termination_reason, :usage, :error]
  end

  @type opts :: [
          model: ReqLLM.model_input(),
          tools: [module()],
          system_prompt: String.t() | nil,
          max_iterations: pos_integer(),
          tool_timeout_ms: pos_integer(),
          temperature: float(),
          max_tokens: pos_integer(),
          llm_opts: keyword()
        ]

  @spec run(String.t(), opts()) :: Result.t()
  def run(query, opts) do
    # 1. Build initial ReqLLM.Context: system_prompt + user query.
    # 2. Convert action modules → ReqLLM.Tool list via Jido.AI.ToolAdapter.
    # 3. Convert action modules → action lookup map for tool dispatch.
    # 4. Build llm_opts (max_tokens, temperature, tools, plus user overrides).
    # 5. Loop until terminal:
    #    a. ReqLLM.Generation.generate_text(model, Context.to_messages(context), llm_opts).
    #    b. Project response → Jido.AI.Turn.from_response.
    #    c. Append assistant message to context (text + tool_calls if any).
    #    d. If final_answer: return Result.
    #    e. If tool_calls: for each tool_call,
    #       - look up action module by name,
    #       - coerce arguments via Jido.Action.Tool.convert_params_using_schema/2,
    #       - run via Jido.Exec.run/4 with %{} as slice (tools shouldn't depend on slice),
    #       - append tool message with result (Jason-encoded on success, error blob on failure),
    #    f. Increment iteration; if > max_iterations, return Result with
    #       termination_reason: :max_iterations.
    #    g. If new tool_calls signature == previous signature, append the
    #       cycle warning user message before next loop iteration.
  end
end
```

### `test/jido/ai/react_test.exs`

Bottom-up coverage using **Mimic** to stub `ReqLLM.Generation.generate_text/3`.
Each test sets up a sequence of expected calls and the response each
returns.

```elixir
defmodule Jido.AI.ReActTest do
  use ExUnit.Case, async: true
  use Mimic

  setup :verify_on_exit!
  setup :set_mimic_global

  setup do
    copy(ReqLLM.Generation)
    :ok
  end

  alias Jido.AI.Test.{TestAdd, TestMultiply, TestFails}

  test "final answer on first turn" do
    expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
      assert length(messages) == 2  # system + user
      {:ok, final_answer_response("42")}
    end)

    result = Jido.AI.ReAct.run("What is the answer?",
      model: "anthropic:claude-haiku-4-5-20251001",
      tools: [],
      system_prompt: "You are helpful.",
      max_iterations: 5)

    assert result.text == "42"
    assert result.iterations == 1
    assert result.termination_reason == :final_answer
  end

  # ... 9 more cases below
end
```

Cases:

1. **Final answer on first turn.** Expect 1 LLM call. Final answer "42".
2. **One tool call, then final answer.** Expect 2 LLM calls. Turn 1
   tool_calls → tool runs → turn 2 final answer. Conversation has 4
   messages.
3. **Two parallel tool calls in one turn.** Expect 2 LLM calls. Both
   tools run before next LLM call. Single iteration step (one round of
   tools, not two).
4. **Tool execution error.** `TestFails` returns `{:error, :boom}`.
   Conversation captures the error blob; loop continues to a final
   answer turn.
5. **Tool call with unknown tool name.** Tool result is
   `{"error": "tool not found: ghost"}`; loop continues.
6. **Max iterations.** Mimic 11 successive tool-call responses.
   `max_iterations: 10`. Termination reason `:max_iterations`,
   iterations == 10.
7. **Cycle detection (same call twice in a row).** Two identical
   tool_calls turns; assert that the third LLM call's `messages`
   includes the cycle warning user message.
8. **LLM error.** Mimic returns `{:error, :rate_limited}`.
   Termination reason `:error`, error == `:rate_limited`.
9. **Empty tools list.** Run without tools; the call to
   `ReqLLM.Generation.generate_text/3` has `tools: []` in opts.
10. **System prompt threading.** Run with `system_prompt: "Be terse."`;
    assert that the system message is at index 0 in the projected
    `Context.to_messages/1`.

The cycle warning text matches `jido_ai`'s `@cycle_warning`:

> "You already called the same tool(s) with identical parameters in the
> previous iteration and got the same results. Do NOT repeat the same
> calls. Either use the results you already have to form a final
> answer, or try a different approach."

This is a load-bearing prompt — the model has been observed to comply
with it. Don't paraphrase.

### `test/support/jido/ai/response_fixtures.ex`

Helper builders for `ReqLLM.Response` test fixtures:

```elixir
defmodule Jido.AI.Test.ResponseFixtures do
  @moduledoc false

  alias ReqLLM.{Message, Response}
  alias ReqLLM.Message.ContentPart

  def final_answer_response(text), do: # ...
  def tool_call_response([{name, args} | _] = calls), do: # ...
  def mixed_response(text, calls), do: # ...
end
```

Lives under `test/support/`, only compiles in `:test`.

## Files to modify

### `mix.exs`

Add `:mimic` to test deps if not already present (it isn't — verify
against jido's existing test deps; `mimic` is the new addition for v1).

```elixir
{:mimic, "~> 2.0", only: :test}
```

If a different stub library is already in use (`mock`, `meck`, etc.),
default to that instead of adding a new one. Check
`lib/jido/.../test/` patterns first.

### `lib/jido/exec.ex`

Verify that `Jido.Exec.run/4` is callable as
`(action_module, params_map, ctx_map, opts_keyword)` directly without
needing a real `%Jido.Signal{}` — the developer-affordance entry point per
the tasks/README guidance. If yes, no edit. If the canonical path
requires a slice argument, the ReAct loop passes `%{}` as the slice (tools
shouldn't depend on slice state). If that doesn't work either, this
task **stops** and a separate task adds the affordance — we do not add a
special "tool exec" pathway around `Jido.Exec`.

## Files to delete

None.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix test test/jido/ai/react_test.exs` passes all 10 scenarios.
- `mix dialyzer` clean.
- `mix credo --strict` clean.
- `mix format --check-formatted` clean.
- Public module: `Jido.AI.ReAct` (and `Jido.AI.ReAct.Result`).
- The runtime is callable as `Jido.AI.ReAct.run("query", model: ..., tools: [...])`
  from anywhere — no agent dep.
- No references from `lib/jido/` outside `lib/jido/ai/` to this module.
- Mimic verifies all stubbed calls were exercised (`verify_on_exit!`).
- The runner does not import from
  `Jido.AI.Reasoning.ReAct.Strategy` / `.Runner` / `.Config` / `.State` /
  `.Token` / `.PendingInput` (those live in `jido_ai`, not in this tree).

## Out of scope

- **Streaming.** v1 calls `ReqLLM.Generation.generate_text/3`, not
  `stream_text/3`. No delta channel.
- **Checkpoint tokens / resume.** v1 has no resume.
- **Steering / injection.** No mid-run user input.
- **Async tool execution.** Tools run sequentially in this task. Task
  0023 switches to async via the `ToolExec` directive.
- **Per-tool timeout / retry.** Uses `Jido.Exec`'s defaults.
- **Multi-strategy reasoning.** Only ReAct in v1.
- **Pending input, request transformer, effect policy, external
  observability signals.** All from `jido_ai`'s ReAct runner; none in v1.
- **Custom system-prompt template.** v1 takes whatever the caller passes.
  jido_ai's `Helpers.build_system_prompt/2` machinery is dropped.

## Risks

- **`Jido.Exec.run/4` slice argument.** The action signature is
  `run(signal, slice, opts, ctx)`. Tools called from ReAct don't have a
  natural slice — they're context-free transformations. The runner can
  either:
  - (a) pass `%{}` as the slice and rely on the action's `path:` not
    reading from it, or
  - (b) call a slimmer entry point in `Jido.Exec` if one exists.
  Audit `Jido.Exec.run/4`'s contract before writing the call site. If
  every action requires a non-empty slice (because the framework hardens
  this), tools wouldn't compose with ReAct, which would surface a real
  framework gap — surface it as a separate task.
- **Tool argument coercion.** The model returns `arguments` with string
  keys; actions want atom keys. Use
  `Jido.Action.Tool.convert_params_using_schema/2` directly. Confirm
  it's exported from `Jido.Action.Tool`.
- **Cycle detection false positives.** Two identical calls might be
  legitimate (calculator twice with same args). The warning is
  light-touch (extra user message, not a hard stop) and matches
  `jido_ai`'s behaviour.
- **Synchronous loop blocks the caller.** A 5-iteration ReAct call with
  a slow LLM blocks for ~30+ seconds. Document this in the moduledoc;
  callers who want async use the agent envelope from task 0023.
- **No supervision.** A crash inside a tool action propagates up.
  Matches `Jido.Exec`'s behaviour. The agent envelope in task 0023
  wraps the loop in a Task so a crash becomes a slice mutation.
- **Mimic vs the existing test stub library.** Verify which library is
  in use already; using a second one bloats test deps. If `mock` or
  `mimic` is already there, prefer that.
- **`ReqLLM.Response` fixture stability.** The struct shape is stable
  but `req_llm` may add fields between minor versions. Use
  `ReqLLM.Response`'s public constructors where they exist; only
  reach for `struct/2` when no constructor covers the case.
