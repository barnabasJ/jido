---
name: Task 0023 — `Jido.AI.Agent` macro + slice + plugin + actions + custom directives
description: Wire the synchronous ReAct loop from task 0022 into the agent runtime as a signal-driven state machine. Define the slice (carrying `ReqLLM.Context` directly), the four lifecycle actions, the two custom directives, and the `use Jido.AI.Agent` macro that ties it together.
---

# Task 0023 — `Jido.AI.Agent` macro + slice + plugin + actions + custom directives

- Implements: [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §5, §6.
- Depends on: [task 0021](0021-reqllm-dep-and-tool-adapter.md), [task 0022](0022-react-runtime-pure.md).
- Blocks: [task 0024](0024-llm-agent-livebook-and-local-integration-test.md).
- Leaves tree: **green**.

## Goal

Bring the LLM-agent surface online. After this commit, a user can:

```elixir
defmodule MyApp.MathAgent do
  use Jido.AI.Agent,
    name: "math",
    description: "Does math.",
    model: "anthropic:claude-haiku-4-5-20251001",   # any ReqLLM-supported spec
    tools: [MyApp.Actions.Add, MyApp.Actions.Multiply],
    system_prompt: "You are a precise mathematician.",
    max_iterations: 6
end

{:ok, pid} = Jido.AgentServer.start(agent: MyApp.MathAgent)
{:ok, request} = MyApp.MathAgent.ask(pid, "What is 5 + 7 * 2?")
{:ok, "19"} = MyApp.MathAgent.await(request, timeout: 30_000)
```

The runtime is signal-driven per ADR 0022 §5: agent actions mutate the
slice and emit `LLMCall` / `ToolExec` directives whose executors run the
side effects in spawned Tasks and emit completion signals back. The loop
is one slice mutation per signal arriving; no synchronous blocking.

## Files to create

### `lib/jido/ai/slice.ex`

The agent's domain slice. Path: `:ai`. Conversation state carried as
`ReqLLM.Context` directly (per ADR 0022 §3) — no wrapper.

```elixir
defmodule Jido.AI.Slice do
  use Jido.Slice,
    path: :ai,
    schema: [
      status: [type: :atom, default: :idle],   # :idle | :running | :completed | :failed
      context: [type: {:struct, ReqLLM.Context}, default: nil],
      iteration: [type: :integer, default: 0],
      result: [type: :any, default: nil],
      error: [type: :any, default: nil],
      request_id: [type: :string, default: nil],
      pending_tool_calls: [type: {:list, :map}, default: []],
      tool_results_received: [type: {:list, :map}, default: []],
      max_iterations: [type: :integer, default: 10],
      previous_tool_signature: [type: :any, default: nil]
    ],
    actions: [
      Jido.AI.Actions.AskStarted,
      Jido.AI.Actions.LLMTurn,
      Jido.AI.Actions.ToolResult,
      Jido.AI.Actions.Failed
    ],
    signal_routes: [
      {"ai.react.ask", Jido.AI.Actions.AskStarted},
      {"ai.react.llm.completed", Jido.AI.Actions.LLMTurn},
      {"ai.react.tool.completed", Jido.AI.Actions.ToolResult},
      {"ai.react.failed", Jido.AI.Actions.Failed}
    ]
end
```

Per ADR 0017, slice-owned routes live on the slice, not on the agent.

### `lib/jido/ai/actions/ask_started.ex`

Fires on `ai.react.ask`. Seeds the slice with a fresh `ReqLLM.Context`,
marks status `:running`, and emits an `LLMCall` directive to start the
first turn.

```elixir
defmodule Jido.AI.Actions.AskStarted do
  use Jido.Action,
    name: "ai_react_ask_started",
    path: :ai,
    schema: [
      query: [type: :string, required: true],
      system_prompt: [type: :string, default: nil],
      tools: [type: {:list, :atom}, default: []],
      model: [type: :any, required: true],
      max_iterations: [type: :integer, default: 10],
      request_id: [type: :string, required: true],
      llm_opts: [type: :keyword_list, default: []]
    ]

  alias Jido.AI.Directive
  alias ReqLLM.Context

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    cond do
      slice.status == :running ->
        # ADR 0022: single active run per agent in v1.
        {:error, :busy}

      true ->
        context =
          Context.new(system_prompt: data.system_prompt)
          |> Context.append_user(data.query)

        new_slice = %{slice |
          status: :running,
          context: context,
          iteration: 1,
          request_id: data.request_id,
          result: nil,
          error: nil,
          pending_tool_calls: [],
          tool_results_received: [],
          max_iterations: data.max_iterations,
          previous_tool_signature: nil
        }

        directive = %Directive.LLMCall{
          model: data.model,
          context: context,
          tools: data.tools,
          request_id: data.request_id,
          llm_opts: data.llm_opts
        }

        {:ok, new_slice, [directive]}
    end
  end
end
```

(Confirm `ReqLLM.Context` exposes `new/1` with `:system_prompt` and
`append_user/2` — if the API is `Context.new/0` plus a `system` message
push, adjust the calls. The intent is unchanged.)

### `lib/jido/ai/actions/llm_turn.ex`

Fires on `ai.react.llm.completed`. Carries a `Jido.AI.Turn` payload. If
`final_answer`, mark `:completed`. If `tool_calls`, store them in
`pending_tool_calls`, append the assistant message to `context`, and emit
one `ToolExec` directive per call. Reject stale signals (different
`request_id`).

If max iterations would be exceeded by continuing, mark `:completed` with
the truncated-result message.

If the new tool-call signature equals `previous_tool_signature`, append a
cycle-warning user message to the context **before** firing the next
LLMCall. Same `@cycle_warning` text as task 0022.

### `lib/jido/ai/actions/tool_result.ex`

Fires on `ai.react.tool.completed`. Each completion signal corresponds to
one tool call. Append the tool result message to `context`, add the
result to `tool_results_received`. Once
`length(tool_results_received) == length(pending_tool_calls)`, emit the
next `LLMCall` directive and clear `pending_tool_calls` /
`tool_results_received`.

Reject stale signals (different `request_id`).

### `lib/jido/ai/actions/failed.ex`

Fires on `ai.react.failed`. Marks `:failed`, stores error.

### `lib/jido/ai/directive/llm_call.ex`

```elixir
defmodule Jido.AI.Directive.LLMCall do
  @type t :: %__MODULE__{
          model: ReqLLM.model_input(),
          context: ReqLLM.Context.t(),
          tools: [module()],
          request_id: String.t(),
          llm_opts: keyword()
        }
  defstruct [:model, :context, :tools, :request_id, :llm_opts]
end
```

### `lib/jido/ai/directive/llm_call/executor.ex` (or wherever the project's directive-executor convention lands them)

Per ADR 0019, the executor returns `:ok | {:stop, term()}` and emits a
signal back to the agent for the side effect's result. It does not return
state.

```elixir
defmodule Jido.AI.Directive.LLMCall.Executor do
  @behaviour Jido.Agent.Directive   # or whatever the post-task-0015 contract is

  alias Jido.AI.{Turn, ToolAdapter}
  alias ReqLLM.Generation

  @impl true
  def exec(%Jido.AI.Directive.LLMCall{} = d, ctx, _opts) do
    Task.start(fn ->
      reqllm_tools = ToolAdapter.from_actions(d.tools)
      messages = ReqLLM.Context.to_messages(d.context)

      llm_opts =
        d.llm_opts
        |> Keyword.put(:tools, reqllm_tools)
        |> maybe_default_max_tokens()

      case Generation.generate_text(d.model, messages, llm_opts) do
        {:ok, response} ->
          turn = Turn.from_response(response, model: model_label(d.model))
          dispatch(ctx, "ai.react.llm.completed", %{
            turn: turn,
            request_id: d.request_id,
            model: d.model,
            tools: d.tools,
            llm_opts: d.llm_opts
          })

        {:error, reason} ->
          dispatch(ctx, "ai.react.failed", %{
            reason: reason,
            request_id: d.request_id
          })
      end
    end)

    :ok
  end

  defp dispatch(ctx, type, data), do:
    Jido.AgentServer.cast(ctx.agent_pid, Jido.Signal.new!(type, data))
end
```

`ctx.agent_pid` access path: confirm against
`lib/jido/agent_server.ex`'s ctx-construction code (per ADR 0014 / task
0002, runtime identity is on the ctx). Don't introduce a new lookup
pathway.

### `lib/jido/ai/directive/tool_exec.ex` + executor

```elixir
defmodule Jido.AI.Directive.ToolExec do
  @type t :: %__MODULE__{
          tool_call: %{id: String.t(), name: String.t(), arguments: map()},
          tool_modules: [module()],
          request_id: String.t()
        }
  defstruct [:tool_call, :tool_modules, :request_id]
end
```

Executor:

1. Spawns a `Task`.
2. Resolves `tool_call.name` to an action module via the action map.
3. Coerces arguments via `Jido.Action.Tool.convert_params_using_schema/2`.
4. Calls `Jido.Exec.run/4`.
5. On success or controlled error: emits `ai.react.tool.completed` with
   `{tool_call_id, name, content, request_id}`. Content is
   `Jason.encode!(result)` on success, or `{"error": "..."}` on failure.
6. On crash: catches and emits `ai.react.tool.completed` with the error
   serialized as content. Tool errors are conversational data, not run
   failures — by design.

### `lib/jido/ai/agent.ex`

The macro that ties it together.

```elixir
defmodule Jido.AI.Agent do
  @default_max_iterations 10
  @default_max_tokens 4_096
  @default_temperature 0.2

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    model = Keyword.fetch!(opts, :model)
    tools = Keyword.get(opts, :tools, [])
    system_prompt = Keyword.get(opts, :system_prompt)
    max_iter = Keyword.get(opts, :max_iterations, @default_max_iterations)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    description = Keyword.get(opts, :description, "AI agent #{name}")

    quote do
      use Jido.Agent,
        name: unquote(name),
        description: unquote(description),
        path: :ai,
        plugins: [Jido.AI.Slice]

      @ai_model unquote(model)
      @ai_tools unquote(tools)
      @ai_system_prompt unquote(system_prompt)
      @ai_max_iter unquote(max_iter)
      @ai_default_llm_opts [
        max_tokens: unquote(max_tokens),
        temperature: unquote(temperature)
      ]

      def ask(pid, query, opts \\ []) do
        request_id = "req_" <> Jido.Util.generate_id()

        signal_data = %{
          query: query,
          system_prompt: opts[:system_prompt] || @ai_system_prompt,
          tools: opts[:tools] || @ai_tools,
          model: opts[:model] || @ai_model,
          max_iterations: opts[:max_iterations] || @ai_max_iter,
          request_id: request_id,
          llm_opts: Keyword.merge(@ai_default_llm_opts, Keyword.get(opts, :llm_opts, []))
        }

        signal = Jido.Signal.new!("ai.react.ask", signal_data)

        # Subscribe BEFORE casting (ADR 0021) for the terminal slice transition.
        {:ok, sub_ref} =
          Jido.AgentServer.subscribe(pid, "**", fn s ->
            ai = s.agent.state.ai

            cond do
              ai.request_id == request_id and ai.status == :completed ->
                {:ok, %{status: :completed, result: ai.result}}

              ai.request_id == request_id and ai.status == :failed ->
                {:ok, %{status: :failed, error: ai.error}}

              true ->
                :skip
            end
          end, once: true)

        case Jido.AgentServer.cast(pid, signal) do
          :ok -> {:ok, %Jido.AI.Request{id: request_id, sub_ref: sub_ref, agent_pid: pid}}
          {:error, _} = err -> err
        end
      end

      def await(%Jido.AI.Request{} = req, opts \\ []) do
        timeout = Keyword.get(opts, :timeout, 30_000)

        receive do
          {:jido_subscription, ref, %{result: {:ok, %{status: :completed, result: r}}}}
              when ref == req.sub_ref ->
            {:ok, r}

          {:jido_subscription, ref, %{result: {:ok, %{status: :failed, error: e}}}}
              when ref == req.sub_ref ->
            {:error, e}
        after
          timeout -> {:error, :timeout}
        end
      end

      def ask_sync(pid, query, opts \\ []) do
        with {:ok, req} <- ask(pid, query, opts), do: await(req, opts)
      end
    end
  end
end
```

### `lib/jido/ai/request.ex`

```elixir
defmodule Jido.AI.Request do
  @type t :: %__MODULE__{id: String.t(), sub_ref: reference(), agent_pid: pid()}
  defstruct [:id, :sub_ref, :agent_pid]
end
```

### Tests

#### `test/jido/ai/agent_test.exs`

Integration tests. Each test uses **Mimic** on `ReqLLM.Generation.generate_text/3`
to script the LLM responses; no real network. Each test starts a real
`Jido.AgentServer` so the signal-routing path is exercised end-to-end.

Cases:

1. **Final answer on first turn** — `ask_sync/2` returns `{:ok, "answer"}`.
   Slice ends in `:completed`. Context has 2 messages.
2. **Single tool call** — turn 1 tool_calls → tool runs → turn 2 final
   answer. Two LLM calls expected via Mimic, in order.
3. **Two parallel tool calls** — both ToolExec directives launch, both
   results come back, single LLMCall fires after, final answer.
4. **Tool error** — failing action returns `{:error, ...}`. Conversation
   captures the error blob. Model produces a final answer. Test
   asserts `await/2` returns `{:ok, ...}`.
5. **Max iterations** — Mimic 11 successive tool-call responses. Slice
   transitions to `:completed` with truncated-result message.
6. **Concurrent ask while running** — second `ask/2` returns
   `{:error, :busy}`. After first completes, third `ask/2` succeeds.
7. **Stale signal handling** — a `tool.completed` signal for a different
   `request_id` is ignored.
8. **`ai.react.failed` from LLM error** — Mimic returns
   `{:error, :rate_limited}`. Slice transitions to `:failed`,
   `await/2` returns `{:error, :rate_limited}`.
9. **Cycle warning prepended** — two identical tool-call turns; the
   third LLM call's messages include the cycle warning.

#### `test/jido/ai/directive/llm_call_test.exs`

Unit test: given a directive, the executor spawns a task, the task hits
ReqLLM (Mimic-stubbed), and emits the right signal back to the agent
(verified with a stub agent process that records casts).

#### `test/jido/ai/directive/tool_exec_test.exs`

Unit test: given a directive with a tool_call, runs the action and emits
the right signal.

## Files to modify

### `lib/jido/agent_server/directive_exec.ex` (or directive_executors.ex)

Verify that custom directives (`%Jido.AI.Directive.LLMCall{}`,
`%Jido.AI.Directive.ToolExec{}`) get routed to their executors via the
existing dispatch mechanism. ADR 0014 / 0015 / 0019 set this up. Read
the dispatcher first; the wedge shape depends on what's there. Keep the
touch surgical.

### `mix.exs`

Add the new modules to `groups_for_modules` under "Jido AI":

```elixir
"Jido AI": [
  Jido.AI.Agent,
  Jido.AI.ReAct,
  Jido.AI.ReAct.Result,
  Jido.AI.Request,
  Jido.AI.Slice,
  Jido.AI.ToolAdapter,
  Jido.AI.Turn,
  ~r/Jido\.AI\.Actions\..*/,
  ~r/Jido\.AI\.Directive\..*/
]
```

## Files to delete

None.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix test test/jido/ai/agent_test.exs` passes all 9 scenarios.
- `mix test test/jido/ai/directive/` passes.
- `mix test` end-to-end is clean (no regressions).
- `mix dialyzer` clean.
- `mix credo --strict` clean.
- `mix format --check-formatted` clean.
- The example agent in this task's docstring (`MyApp.MathAgent`) compiles.
- ADR 0019 conformance: every action in `lib/jido/ai/actions/` returns
  either `{:ok, slice, [directive]}` or `{:error, reason}`. No action
  performs I/O. No directive executor returns state.
- ADR 0021 conformance: `await/2` does not poll; it `receive`s the
  subscription notification. No `eventually_state/3`. No `fn s -> {:ok, s} end`.
- ADR 0017 conformance: signal routes for `ai.react.*` live on
  `Jido.AI.Slice`'s `signal_routes:` option, not on the agent's
  `signal_routes/1` callback.

## Out of scope

- **Streaming.** No deltas. The agent emits a single terminal transition.
- **Multi-run concurrency.** Single active run per agent. `ask/2` while
  running returns `{:error, :busy}`.
- **Steering / injection.** No `steer/2` or `inject/2` API.
- **Per-request observability traces.** No `request_traces` field. The
  slice carries the full `ReqLLM.Context`, sufficient for v1.
- **Persistence of in-progress runs.** If the agent crashes mid-run, the
  run is lost.
- **Tool execution retry / compensation hooks.** Inherits from
  `Jido.Exec`'s built-in retry; no LLM-specific layer.
- **Custom request transformer.** Not in v1.
- **Skills.** No Skills system. Tools are passed as a flat list.
- **Effect policy.** No effect-policy gating. Tools are trusted.
- **`Jido.AI.Plugin` as a separate module.** v1 lets `Jido.AI.Slice` be
  the only attached unit (slices register routes; they ARE the plugin
  per ADR 0017's terminology unification). If a cross-cutting plugin
  surface emerges later — observability, telemetry, config — split it
  out then.

## Risks

- **Custom directive dispatch.** The framework's dispatcher may use
  protocol-style extensibility, behaviour-callback per executor module,
  or pattern matching by struct type. Read
  `lib/jido/agent_server/directive_exec.ex` and
  `lib/jido/agent_server/directive_executors.ex` first; the wedge
  shape depends on what's there.

- **`ctx.agent_pid` access path.** The directive executor needs to know
  which agent to send the completion signal back to. Per ADR 0014 +
  task 0002, runtime identity lives on the ctx. Find the canonical
  access path; don't reinvent.

- **Subscription timing race.** `ask/2` subscribes before casting, but
  there's a window between subscription setup and signal dispatch.
  Read `Jido.AgentServer.subscribe/4`'s contract to confirm pre-cast
  registration is sufficient. If there's a race, the subscribe API
  needs a fix — separate task, not this one.

- **`**` selector pattern catches all signals.** Used in `ask/2` to
  watch the slice for the terminal transition. The selector function
  guards by `request_id` and status, so spurious matches are ignored.
  Confirm the agent's signal-after-action emission contract — if the
  router emits a signal *and then* runs the action that updates the
  slice, the selector might see stale status. Check
  `Jido.AgentServer.SignalRouter`'s ordering.

- **Model spec capture in macro.** `model: "anthropic:claude-..."` is
  a literal string — captures cleanly. If a user passes a
  `{module, opts}` spec or a `%ReqLLM.Model{}` struct, the AST may
  contain aliases that need expansion. Match
  `jido_ai/lib/jido_ai/agent.ex`'s `expand_aliases_in_ast/2` pattern
  if needed. Runtime overrides via `ask/3`'s `model:` opt skip the
  compile-time path.

- **`ReqLLM.Context` API drift.** Confirm the constructor and
  append helpers (`Context.new/1`, `Context.append_user/2`,
  `Context.append_assistant/3`, `Context.append_tool/3`,
  `Context.to_messages/1`) against the pinned `req_llm` version
  before writing slice/action code. If the API uses different
  function names, adjust the call sites; the slice still carries
  `%ReqLLM.Context{}`.

- **Stale signal robustness.** The `request_id` guard is the only
  defense against a stale signal landing on a fresh run. Make sure
  every action checks it; an unguarded `LLMTurn` action could corrupt
  a new run with a previous run's response.

- **Tool result ordering.** Multiple `ToolExec` directives spawn
  concurrent tasks. Their `tool.completed` signals may arrive in any
  order. The action appends each to `tool_results_received`; the
  context's tool messages may end up in non-call order. ReqLLM /
  most providers tolerate out-of-order tool results as long as each
  tool message has the correct `tool_call_id`. Confirm against
  Anthropic's contract; if order matters, the action sorts by
  `pending_tool_calls` order before firing the next LLMCall.
