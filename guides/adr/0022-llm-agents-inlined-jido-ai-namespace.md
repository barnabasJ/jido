# 0022. LLM agents are first-class — `Jido.AI.*` inlined in jido on top of `req_llm`, signal-driven ReAct

- Status: Proposed
- Implementation: Pending — tracked by tasks [0021](../tasks/0021-reqllm-dep-and-tool-adapter.md), [0022](../tasks/0022-react-runtime-pure.md), [0023](../tasks/0023-llm-agent-slice-plugin.md), [0024](../tasks/0024-llm-agent-livebook-and-local-integration-test.md).
- Date: 2026-04-27
- Related ADRs: [0014](0014-slice-middleware-plugin.md), [0018](0018-tagged-tuple-return-shape.md), [0019](0019-actions-mutate-state-directives-do-side-effects.md), [0021](0021-no-full-state-no-polling.md)

## Context

LLM-driven agents are a primary use case for the framework, but today they
live in a separate package (`jido_ai`). That package was built on the older
`Jido.Agent.Strategy` abstraction — retired in ADR 0011 / ADR 0013 — and on a
sprawling Reasoning/Skills/Plugins layer that predates the Slice / Middleware
/ Plugin redesign in ADR 0014. The runtime in
`Jido.AI.Reasoning.ReAct.Runner` also predates ADR 0019 (actions don't do
side effects) and ADR 0021 (no polling, no full-state reads), and bakes those
antipatterns into its core shape: a single coordinator task drives the loop,
threads full runtime state through dozens of helpers, and emits external
signals as a side-channel rather than as the primary control plane.

A user who wants an LLM agent today has three options, all bad:

1. Pull in `jido_ai` and accept the dead Strategy abstraction plus a
   5,900-line ReAct subsystem that doesn't compose with the new
   slice/plugin model.
2. Build their own using `req_llm` directly, re-implementing tool exposure,
   the reasoning loop, and the agent integration.
3. Wait for `jido_ai` to be rewritten on the new core, which is a project
   of indeterminate scope.

The right move is to inline a minimal LLM-agent subsystem **directly into
jido**, designed from the start around slices/middleware/plugins, ADR 0019's
strict directive rule, and ADR 0021's signal-driven waits. Existing pieces
of `jido_ai` that already match the framework's discipline — `ToolAdapter`,
the ReAct prompt shape, the `Turn` projection — are ported. Pieces that
don't — the Strategy delegation, the FSM, the coordinator task, checkpoint
tokens, the multi-strategy reasoning catalogue, the Skills system, the
multi-tier plugin stack — are not.

This ADR is the seed. v1 is deliberately narrow: one reasoning pattern
(ReAct), no streaming, no checkpoint resume, no concurrent runs per agent.
Later ADRs can broaden it.

## Decision

### 1. New namespace: `Jido.AI.*`, inlined under `lib/jido/ai/`

The LLM subsystem ships as part of `jido` — same hex package, same
versioning, same docs site. Module names live under `Jido.AI.*` (mirroring
`jido_ai` for migration). The directory is `lib/jido/ai/`.

We do **not** introduce a new hex package, an optional dep, or an extension
point that loads `Jido.AI.*` at runtime. It's part of the framework. The
runtime cost for a non-AI user is one extra namespace in the docs and a
small amount of additional compiled BEAM modules.

### 2. `req_llm` is the model runtime; we do not wrap it

`req_llm` becomes a direct runtime dep of jido. It owns:

- Provider catalogue (Anthropic, OpenAI, Google, Groq, Mistral, vLLM, Bedrock,
  Cohere, DeepSeek, OpenRouter, xAI, and others).
- Wire-format marshalling per provider — request body, tool-use blocks,
  streaming deltas.
- Public types: `ReqLLM.Context`, `ReqLLM.Message`, `ReqLLM.Message.ContentPart`,
  `ReqLLM.Tool`, `ReqLLM.Response`, `ReqLLM.ToolResult`.
- The `ReqLLM.Generation.generate_text/3` and `ReqLLM.Generation.stream_text/3`
  entry points.

The LLM-agent subsystem **uses these types directly**. We do not write a
`Jido.AI.Model` behaviour, do not wrap `ReqLLM.Context` in a parallel
`Jido.AI.Conversation`, and do not invent message/turn structs that
duplicate `ReqLLM.Message` and `ReqLLM.Response`. The single thin wrapper
we keep is `Jido.AI.Turn`, which is a normalized `ReqLLM.Response`
projection that classifies the response as `:tool_calls` vs
`:final_answer` and exposes the bits the ReAct loop needs — see §4.

The model spec accepted by the agent is whatever `ReqLLM.Generation`
accepts: a string (`"anthropic:claude-haiku-4-5-20251001"`,
`"google:gemma-3-27b"`, `"openai:gpt-5"`), a `ReqLLM.Model.t()`, or a
`{provider, opts}` tuple. The agent does no spec validation beyond what
ReqLLM does itself.

### 3. Conversation state uses `ReqLLM.Context`

Run state inside the slice carries a `%ReqLLM.Context{}` directly:

```elixir
%Jido.AI.Slice{
  status: :idle | :running | :completed | :failed,
  context: %ReqLLM.Context{},     # system prompt + messages
  iteration: non_neg_integer(),
  ...
}
```

`ReqLLM.Context.append_user/2`, `Context.append_assistant/3`,
`Context.append_tool/3` are the mutation helpers; the ReAct actions in §6
use them directly. No `Jido.AI.Conversation` wrapper.

### 4. Tools: port `Jido.AI.ToolAdapter` and `Jido.AI.Turn` from `jido_ai`

`jido_ai`'s `Jido.AI.ToolAdapter` already does the right thing — it converts
`Jido.Action` modules into `ReqLLM.Tool` structs, with strict-mode JSON
Schema sanitization (`additionalProperties: false` on every nested object),
prefix support, and duplicate-name detection. **Port it verbatim**, dropping
only the now-obsolete `function_exported?(ActionSchema, :to_json_schema, 2)`
back-compat branch since this jido tree has the post-task-0000 unified
action surface.

The companion `Jido.AI.Turn` from `jido_ai` (the `from_response/2` projector)
also ports verbatim, simplified to drop the
streaming/`tool_results`/observability fields that v1 doesn't use. What
survives:

```elixir
defmodule Jido.AI.Turn do
  @type t :: %__MODULE__{
          type: :tool_calls | :final_answer,
          text: String.t(),
          tool_calls: [%{id: String.t(), name: String.t(), arguments: map()}],
          usage: map(),
          finish_reason: atom() | nil,
          model: String.t() | nil
        }
end
```

Tool **execution** during a ReAct loop runs through `Jido.Exec.run/4`
against the action module (with arguments coerced via
`Jido.Action.Tool.convert_params_using_schema/2`). The action is the
canonical execution path; ReAct just wires `ReqLLM.Message` tool-use blocks
into a `Jido.Exec.run/4` call and the result back into the conversation as
a `:tool` message.

### 5. ReAct as a signal-driven state machine, not a coordinator task

ADR 0019 says actions mutate state and directives do side effects. ADR 0021
says waits subscribe; they don't poll. A ReAct loop is fundamentally a
sequence of side effects (LLM call, tool exec, LLM call, tool exec, …)
interleaved with state mutations (record turn, record tool result,
finalize). The natural mapping is **signal-driven**:

| Step | Side effect | Signal back | Action mutates |
|---|---|---|---|
| `ai.react.ask` arrives | — | — | seed run state, append user msg |
| Need an LLM turn | `LLMCall` directive launches Task that calls `ReqLLM.Generation.generate_text/3` | `ai.react.llm.completed` | append assistant msg + tool_calls |
| Need to run a tool | `ToolExec` directive launches `Jido.Exec.run/4` | `ai.react.tool.completed` | append tool result msg |
| Final answer reached | — | `ai.react.completed` (emitted) | mark done, store result |
| Max iterations hit | — | `ai.react.completed` (truncated) | mark done |
| LLM/tool error | — | `ai.react.failed` (emitted) | mark failed, store error |

Each transition is one signal arriving, one action firing, one slice
mutation, zero or one outbound directive. There is **no coordinator
task**, no inline-blocking on LLM calls, no polling. Each LLM/tool call
runs as a child task spawned via the `LLMCall` / `ToolExec` directive;
when it completes, it emits a signal back to the agent. The agent's
signal router applies that signal to the slice via the relevant action.

Custom directives `%Jido.AI.Directive.LLMCall{}` and
`%Jido.AI.Directive.ToolExec{}` follow ADR 0019: their executors emit a
signal when the side effect completes and never return state.

Concurrency is **single active run per agent in v1**. A new `ai.react.ask`
arriving while a run is in-flight is rejected (`{:error, :busy}`). ReAct's
`steer/3` and `inject/3` from `jido_ai` are out of scope for v1.

### 6. Agent surface: `use Jido.AI.Agent`

```elixir
defmodule MyApp.WeatherAgent do
  use Jido.AI.Agent,
    name: "weather",
    description: "Answers weather questions",
    model: "anthropic:claude-haiku-4-5-20251001",   # any ReqLLM-supported spec
    tools: [MyApp.Actions.Weather, MyApp.Actions.Forecast],
    system_prompt: "You are a weather expert.",
    max_iterations: 10
end
```

`use Jido.AI.Agent` macro-expands to:

- `use Jido.Agent, path: :ai, schema: <slice schema>` — agent struct with
  the LLM slice.
- `plugins: [Jido.AI.Slice]` — registers `ai.react.*` signal routes (per
  ADR 0017 they live on the slice, not the agent).
- Generated helpers: `ask/3`, `await/2`, `ask_sync/3` — thin wrappers
  around `Jido.AgentServer.cast/3` plus `subscribe/4`, returning a
  `%Jido.AI.Request{}` handle.

The slice carries:

```elixir
%Jido.AI.Slice{
  status: :idle | :running | :completed | :failed,
  context: %ReqLLM.Context{},
  iteration: non_neg_integer(),
  result: term() | nil,
  error: term() | nil,
  request_id: String.t() | nil,
  pending_tool_calls: [tool_call()],
  max_iterations: pos_integer()
}
```

Anything richer (per-request traces, usage breakdowns, multiple concurrent
runs) is later work.

### 7. Tests target a local model — Mimic for unit, local LLM for integration

Two test layers, two rules.

**Unit tests** (the regression net) use **Mimic** to stub
`ReqLLM.Generation.generate_text/3`. Each test scripts the sequence of
`{:ok, %ReqLLM.Response{}}` returns the loop should see, asserts the
slice state at each step, and verifies the Mimic-recorded calls. No
real network traffic. Deterministic. Fast.

**The integration test runs against a local model.** That's the rule —
not "local by default with an escape hatch", not "configurable" — local.
Local Gemma via Ollama is the canonical setup; vLLM or any other
OpenAI-compatible local endpoint also works. The test probes the local
endpoint at setup; if the probe fails, the test **skips** with a
descriptive message. No paid API. No CI secret. Anyone with Ollama
running can run the test; everyone else sees a skip.

If a paid-API smoke check is wanted later, it's a **separate** test
file under a separate tag (`:paid_llm`), explicitly opt-in. It's not
the same test "switched to a different provider via an env var." The
integration test surface is local; paid-API surface is its own thing.

### 8. Livebook: model spec is a configurable input

A new livebook at `guides/llm-agent.livemd` builds a minimal agent
end-to-end: defines two `Jido.Action` modules as tools, defines a
`use Jido.AI.Agent` agent, starts it under `Jido.AgentServer`, calls
`ask_sync/2`, shows the answer.

The rule for the livebook is one thing: **the model spec is a
configurable `Kino.Input` at the top of the livebook.** The reader
picks the provider — Anthropic, OpenAI, Groq, a local endpoint,
whatever ReqLLM supports — by typing into the input. The livebook
doesn't hard-code a provider.

A sensible default for the input is a **separate, secondary
implementation choice** so the cells are runnable on first open. v1
picks a local-Gemma spec for that default, with a setup-cell note
documenting the `ollama pull` / `ollama serve` path; readers without
Ollama swap the input to whatever provider they have a key for. The
default is a UX nicety, not part of the rule.

Cells flow top-to-bottom: setup + model input → tool actions → agent
definition → start + ask → inspect conversation. Every wait is a
subscription (`ask_sync` does this internally); no `Process.sleep`.
Per ADR 0021, full-state reads are forbidden; the inspection cell
uses a projecting selector.

## Consequences

- **Public API gains `Jido.AI.*`.** ~10-12 new modules. Each is small
  (most under 200 LOC). The biggest port is `Jido.AI.ToolAdapter`
  (~330 LOC verbatim from `jido_ai`) and the ReAct runner (~400 LOC
  trimmed from `jido_ai`'s 1,242-line runner).

- **`req_llm` joins jido's runtime deps.** Plus its own transitive
  dependencies (`req`, `jason`, etc.). For a non-AI user, the cost is
  some compile time and a few hundred KB of BEAM bytecode.

- **`jido_ai` users have a migration path, not a runtime upgrade.**
  People on `jido_ai` keep using `jido_ai` until they want to migrate.
  We ship a migration guide as a follow-on task once v1 is stable. The
  two packages have different reasoning catalogues, different runtime
  guarantees, and are not API-compatible — that's fine; one is the new
  architecture, the other is the old. We don't ship shims.

- **No streaming, no checkpoint tokens, no per-agent concurrency in
  v1.** Each is a substantial design decision with its own tradeoffs;
  v1 picks the smallest API that's still useful: cast a query, await a
  result.

- **Signal-driven loop has higher latency floor than coordinator
  task.** Each LLM-call → response → tool-exec → response cycle hits
  the agent server's signal router twice. For a typical 4-5-iteration
  loop that's 8-10 router hops. The hops are local (within-VM) and add
  microseconds; the LLM call itself is 100s of ms. The signal-driven
  shape's cost is negligible relative to the LLM and gives us
  ADR-019/021 conformance for free.

- **`Jido.AI.Plugin` registers cross-cutting routes; agents declare
  their own domain routes on top.** This is the same shape as in-tree
  plugins like `Jido.Identity.Plugin` and matches ADR 0017's
  plugin-vs-slice route ownership clarification.

- **Integration tests run on a local LLM, full stop.** CI skips if
  the local endpoint isn't reachable; developers with Ollama running
  locally see it pass. No CI-secret management for paid APIs in v1.
  Paid-API coverage, if added, is a **separate** test under a
  separate tag — never the same integration test wired to a different
  provider.

- **Compensations, retries, and idempotency for tool calls inherit
  from `Jido.Exec`'s existing behaviour.** Tool exec is just
  `Jido.Exec.run/4` — retries, timeouts, compensation hooks all come
  from the action's configuration. v1 does not add an LLM-specific
  retry layer.

## Alternatives considered

**Build a thin `Jido.AI.Model` behaviour and write per-provider HTTP
clients ourselves.** Pros: smaller dep list, no `req_llm` dep. Cons:
duplicates ReqLLM's provider catalogue, wire-format marshalling, tool
shape conversions, and streaming infrastructure for no real gain. The
"avoid the dep" framing was a shortcut around the actual work of porting
the LLM-agent code we already have. Rejected.

**Port `jido_ai`'s `ReAct.Runner` coordinator task as-is.** Pros:
existing code, already tested under load. Cons: violates ADR 0019 (the
coordinator inlines side effects), violates ADR 0021 (the runner threads
full state through helpers and uses internal selectors that defeat the
projection discipline), and brings ~5,900 LOC including streaming,
checkpoint tokens, pending-input servers, request transformers, FSM
strategy, and worker delegation that v1 doesn't need. Re-implementing
the loop signal-driven is ~400 LOC and is the architecture jido has
already decided on.

**Inline as `Jido.LLM.*` instead of `Jido.AI.*`.** Marginal naming
preference. `Jido.AI.*` matches `jido_ai` and the existing community
vocabulary; renaming for naming-purity reasons would mean every
migration mention has to explain the rename. Not worth the friction.

**Skip ReAct in v1; ship just the tool adapter and a thin LLM-call
action.** That's "a ReqLLM wrapper packaged with jido", not "an LLM
agent framework". The loop is the value; without it users still build
their own runtime. We commit to ReAct as the v1 reasoning shape and add
others (CoT, ToT, etc.) only if there's a specific pull, behind their
own ADRs.

**Express the LLM agent purely as middleware on `Jido.Agent`.**
Middleware runs synchronously per signal and would make the LLM call
inline — same problem as the coordinator task. ReAct needs side effects
out of the synchronous path. The slice + plugin + custom directives +
signal routes shape is the right one.

**Make ReAct concurrent (multiple runs per agent) in v1.** Concurrency
interacts with the slice (per-run state needs separation), the agent's
signal ordering, and the public `ask`/`await` contract. Out of scope
for v1; the single-run rejection makes the failure mode explicit.
Concurrency is a follow-on ADR.

**Make the integration test target a paid API.** That excludes
contributors without API keys, requires CI-secret management, and
costs money per CI run. Local Gemma via Ollama is zero-cost, key-less,
and any contributor can run it. The integration test is **local**,
period. Paid-API coverage, if it's ever wanted, is a separate test
under its own tag.

**Make the livebook hard-code a provider.** The livebook's audience
is "people who want to learn how Jido.AI.Agent works"; that includes
people who use Anthropic, people who use OpenAI, people who run local
models, and people who haven't picked yet. Hard-coding any one
provider excludes the others from running the demo without code edits.
The livebook's rule is "configurable" so the reader picks; whether
the input has a sensible default is a separate, secondary choice.
