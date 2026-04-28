# 0022. LLM agents are first-class — `Jido.AI.*` inlined in jido, ReAct is a slice

- Status: Proposed (revised — see *Revision history* at the bottom)
- Implementation: Tasks [0021](../tasks/0021-reqllm-dep-and-tool-adapter.md) (done),
  [0022](../tasks/0022-react-runtime-pure.md) (done — retired by task 0030),
  [0023](../tasks/0023-llm-agent-slice-plugin.md) (done — superseded by task 0030),
  [0029](../tasks/0029-reject-bare-slice-in-plugins.md),
  [0032](../tasks/0032-framework-slices-attachment-option.md),
  [0030](../tasks/0030-llm-agent-slice-composition-refactor.md),
  [0031](../tasks/0031-llm-agent-livebook-and-tagged-integration-tests.md).
- Date: 2026-04-27 (revised twice — see *Revision history* at the bottom)
- Related ADRs: [0014](0014-slice-middleware-plugin.md), [0017](0017-pod-mutations-are-signal-driven.md),
  [0018](0018-tagged-tuple-return-shape.md), [0019](0019-actions-mutate-state-directives-do-side-effects.md),
  [0021](0021-no-full-state-no-polling.md)

## Context

LLM-driven agents are a primary use case for the framework. Today they live in a
separate package (`jido_ai`) built on retired strategy abstractions and a sprawling
Reasoning/Skills/Plugins layer that predates ADRs 0014, 0017, 0019, and 0021.

A user who wants an LLM agent today has three options, all bad:

1. Pull in `jido_ai` and accept the dead Strategy abstraction plus a 5,900-line
   ReAct subsystem that doesn't compose with the new slice/plugin model.
2. Build their own using `req_llm` directly, re-implementing tool exposure, the
   reasoning loop, and the agent integration.
3. Wait for `jido_ai` to be rewritten on the new core, scope indeterminate.

The right move is to inline a minimal LLM-agent subsystem **directly into jido**,
designed from the start around slices/middleware/plugins, ADR 0019's strict
directive rule, and ADR 0021's signal-driven waits. Existing pieces of `jido_ai`
that match the framework's discipline — `ToolAdapter`, the `Turn` projection —
port verbatim. The rest does not.

This ADR is the seed. v1 is deliberately narrow: one reasoning pattern (ReAct),
no streaming, no checkpoint resume, no concurrent runs per agent.

## Decision

### 1. Namespace — `Jido.AI.*`, inlined under `lib/jido/ai/`

Same hex package, same versioning, same docs site. Module names live under
`Jido.AI.*` (mirroring `jido_ai` for migration). The directory is `lib/jido/ai/`.

We do not introduce a new hex package, an optional dep, or an extension point that
loads `Jido.AI.*` at runtime. It's part of the framework. The cost for a non-AI
user is one extra namespace in the docs and a small amount of additional compiled
BEAM modules.

### 2. `req_llm` is the model runtime; we do not wrap it

`req_llm` is a direct runtime dep of jido. It owns:

- Provider catalogue (Anthropic, OpenAI, Google, Groq, Mistral, vLLM, Bedrock,
  Cohere, DeepSeek, OpenRouter, xAI, and others).
- Wire-format marshalling per provider — request body, tool-use blocks, streaming
  deltas.
- Public types: `ReqLLM.Context`, `ReqLLM.Message`, `ReqLLM.Message.ContentPart`,
  `ReqLLM.Tool`, `ReqLLM.Response`, `ReqLLM.ToolResult`.
- The `ReqLLM.Generation.generate_text/3` and `ReqLLM.Generation.stream_text/3`
  entry points.

The LLM-agent subsystem **uses these types directly**. We do not write a
`Jido.AI.Model` behaviour, do not wrap `ReqLLM.Context` in a parallel
`Jido.AI.Conversation`, and do not invent message/turn structs that duplicate
`ReqLLM.Message` and `ReqLLM.Response`. The single thin wrapper we keep is
`Jido.AI.Turn`, which is a normalized `ReqLLM.Response` projection that
classifies the response as `:tool_calls` vs `:final_answer`.

The model spec accepted by the slice is whatever `ReqLLM.Generation` accepts: a
string (`"anthropic:claude-haiku-4-5-20251001"`, `"google:gemma-3-27b"`,
`"openai:gpt-5"`), a `ReqLLM.Model.t()`, or a `{provider, opts}` tuple. The slice
does no spec validation beyond what ReqLLM does itself.

### 3. Conversation state uses `ReqLLM.Context`

Run state inside the slice carries a `%ReqLLM.Context{}` directly:

```elixir
%{
  status: :idle | :running | :completed | :failed,
  context: %ReqLLM.Context{},     # system prompt + messages
  iteration: non_neg_integer(),
  ...
}
```

`ReqLLM.Context.append/2`, `Context.user/1`, `Context.assistant/2`,
`Context.tool_result/3` are the mutation helpers; the ReAct actions in §5 use them
directly. No `Jido.AI.Conversation` wrapper.

### 4. Tools — port `Jido.AI.ToolAdapter` and `Jido.AI.Turn` from `jido_ai`

`Jido.AI.ToolAdapter` converts `Jido.Action` modules into `ReqLLM.Tool` structs,
with strict-mode JSON Schema sanitization (`additionalProperties: false` on every
nested object), prefix support, and duplicate-name detection. **Ported verbatim**.

The companion `Jido.AI.Turn` (the `from_response/2` projector) ports verbatim,
simplified to drop the streaming/`tool_results`/observability fields v1 doesn't
use:

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

Tool **execution** during a ReAct loop runs through `Jido.Exec.run/4` against the
action module (with arguments coerced via `Jido.Action.Tool.convert_params_using_schema/2`).
The action is the canonical execution path; ReAct just wires `ReqLLM.Message`
tool-use blocks into a `Jido.Exec.run/4` call and the result back into the
conversation as a `:tool` message.

### 5. ReAct as a signal-driven state machine, not a coordinator task

ADR 0019 says actions mutate state and directives do side effects. ADR 0021 says
waits subscribe; they don't poll. A ReAct loop is fundamentally a sequence of
side effects (LLM call, tool exec, LLM call, tool exec, …) interleaved with
state mutations (record turn, record tool result, finalize). The natural mapping
is **signal-driven**:

| Step | Side effect (directive) | Signal back | Action mutates |
|---|---|---|---|
| `ai.react.ask` arrives | — | — | seed run state, append user msg |
| Need an LLM turn | `LLMCall` directive spawns Task → `ReqLLM.Generation.generate_text/3` | `ai.react.llm.completed` | append assistant msg + tool_calls |
| Need to run a tool | `ToolExec` directive spawns Task → `Jido.Exec.run/4` | `ai.react.tool.completed` | append tool result msg |
| Final answer reached | — | — | mark `:completed`, store result |
| Max iterations hit | — | — | mark `:completed` (truncated) |
| LLM error | — | `ai.react.failed` (cast by LLMCall executor) | mark `:failed`, store error |

Each transition is one signal arriving, one action firing, one slice mutation,
zero or more outbound directives. There is **no coordinator task**, no inline
blocking on LLM calls, no polling. Each LLM/tool call runs as a child task spawned
by the directive's executor; when it completes, it casts a signal back to the
agent. The agent's signal router applies that signal to the slice via the relevant
action.

Custom directives `%Jido.AI.Directive.LLMCall{}` and `%Jido.AI.Directive.ToolExec{}`
follow ADR 0019: their executors emit a signal when the side effect completes and
never return state. The directive struct carries every value its executor needs so
the executor doesn't read slice state at exec time (state is read-only in the
executor anyway).

Concurrency is **single active run per agent in v1**. A new `ai.react.ask` while
`status == :running` is rejected (`{:error, :busy}`). `steer/3` and `inject/3`
from `jido_ai` are out of scope.

### 6. ReAct is a slice attached via `slices:` on a regular `Jido.Agent`

There is no `use Jido.AI.Agent` macro. There is no AI-specific agent wrapper.
Users compose a regular `Jido.Agent` with a configured `Jido.AI.ReAct` slice
via the framework's `slices:` option (added in task 0032):

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
```

The agent module declares **no LLM concepts**. It does not name a `path:`, a
`schema:`, or `signal_routes:` for the AI slice — those are slice-internal.

`Jido.AI.ReAct` is `use Jido.Slice` with:

- `path: :ai`
- `actions: [Jido.AI.Actions.{Ask, LLMTurn, ToolResult, Failed}]`
- `signal_routes:` — the four `ai.react.*` routes (absolute paths; no
  plugin-style prefixing happens for `slices:` attachment)
- `schema:` — the slice's state shape (`status`, `request_id`, `context`,
  `iteration`, `result`, `error`, `pending_tool_calls`, etc., plus the
  `model` / `tools` / `system_prompt` / `max_iterations` / `llm_opts`
  run-config fields)
- `config_schema:` — declares `:model`, `:tools`, `:system_prompt`,
  `:max_iterations`, `:max_tokens`, `:temperature`, `:llm_opts` as the keys
  the slice accepts at attachment time

The framework's `slices:` machinery seeds the slice's initial state by
validating the supplied config through `config_schema/0` and merging into the
slice state under `path()` (`:ai`). Per ADR 0017 the slice's signal_routes
land verbatim — no prefix.

`slices:` is **not** `plugins:`. ADR 0014 reserves `plugins:` for `use
Jido.Plugin` modules (Slice + Middleware). Putting `Jido.AI.ReAct` (a bare
slice) in `plugins:` is a compile-time error after task 0029; the right bucket
is `slices:` (added in task 0032).

Multiple slices compose. An agent that wants ReAct alongside a chat slice or
a memory slice just lists them all:

```elixir
slices: [
  Jido.Memory.Slice,
  {Jido.AI.ReAct, model: "...", tools: [...]},
  {MyApp.AnalyticsSlice, sample_rate: 0.1}
]
```

Path collisions across the agent's own `path:`, between two `slices:` entries,
or between a slice and `default_plugins:` raise `CompileError` at the agent
module's compile time.

### 7. User-facing API — `Jido.AI` namespace functions

There are no agent-module-level functions. The user-facing API lives at the
namespace level, and is exactly two functions: `ask/3` (fire-and-forget
launch) and `ask_sync/3` (launch + wait for the final answer).

```elixir
{:ok, pid}        = Jido.AgentServer.start_link(agent_module: MyApp.SupportAgent)

# Convenience: launch and block on the terminal transition.
{:ok, text}       = Jido.AI.ask_sync(pid, "Refund order 42, the customer asked.")

# Or fire-and-forget. Returns immediately once the run is in flight.
{:ok, request_id} = Jido.AI.ask(pid, "What's the status of order 42?")
```

Per-call overrides apply to either function:

```elixir
{:ok, text} =
  Jido.AI.ask_sync(pid, "Use a different model for this one",
    model: "openai:gpt-5",
    tools: [MyApp.Actions.OneOff]
  )
```

#### Internal mechanics

`ask/3` synchronously sends `"ai.react.ask"` via `Jido.AgentServer.call/4`.
The `Jido.AI.Actions.Ask` action is the **single source of truth** for
run-config resolution and validation:

- It resolves per-call → slice fallback for `model`, `tools`,
  `system_prompt`, `max_iterations`, and keyword-merges per-call
  `:llm_opts` over the slice's stored `:llm_opts`.
- It rejects with `{:error, :busy}` when a run is in flight.
- It rejects with `{:error, :no_model}` when no model is available
  anywhere.

`call/4`'s chain-error path delivers those rejections to `ask/3`'s caller
verbatim (wrapped in the framework's standard `%Jido.Error.ExecutionError{}`
envelope, with the rejection reason exposed via `details.reason`). On
success, `ask/3` returns the minted `request_id` so the caller can correlate
it with subsequent signals.

`ask_sync/3` is a convenience that subscribes for the slice's terminal
transition (pre-cast, ADR 0021), launches via `ask/3`, `receive`s the
subscription fire, and returns `{:ok, text}` / `{:error, reason}` /
`{:error, :timeout}`.

#### Subscriptions are out of band

`ask/3` itself sets up no subscriptions — that's a deliberate API shape.
Real consumers want different things from the signal stream: tool-call
notifications for UI updates, streaming tokens, intermediate reasoning
steps, audit trails. The `:completed`/`:failed` filter `ask_sync/3`
applies internally is one specific consumer's needs; the framework
shouldn't bake it in.

Callers who want richer observation subscribe themselves before calling
`ask/3`:

```elixir
{:ok, ref} =
  Jido.AgentServer.subscribe(pid, "ai.react.**", fn state ->
    {:ok, state.agent.state.ai}
  end)

{:ok, request_id} = Jido.AI.ask(pid, "What's the status?")
# receive {:jido_subscription, ^ref, ...} for every signal in the loop
```

#### API keys

Per-tenant keys flow through `:llm_opts`. ReqLLM treats per-request
`:api_key` as the highest-precedence source (above app config and
environment variables). The slice's `Keyword.merge(slice.llm_opts,
data.llm_opts)` plumbs it from either place:

```elixir
# Slice-level default (applies to every run on this agent):
slices: [{Jido.AI.ReAct, model: "...", llm_opts: [api_key: System.fetch_env!("OPENAI_API_KEY")]}]

# Per-call override (multi-tenant):
Jido.AI.ask_sync(pid, "...", llm_opts: [api_key: user.api_key])
```

### 8. Tests — Mimic for unit, tagged-and-excluded for integration

Two layers, two rules.

**Unit tests** stub `ReqLLM.Generation.generate_text/3` via Mimic. Each test scripts
the sequence of `{:ok, %ReqLLM.Response{}}` returns the loop should see, asserts
slice state and emitted directives at each step. No real network. Deterministic.
Fast.

**Integration tests are tagged and excluded by default.** They live under a tag
(`:e2e`) added to `test_helper.exs`'s `ExUnit.configure(exclude: [...])`. The
default `mix test` does not run them. To run them: `mix test --include e2e`.

There is **no probe-and-skip**. The test does not check whether the local endpoint
is reachable and skip on failure; it runs against the configured endpoint, and if
that endpoint is down when the operator opted in via the tag, the test fails. A
probe-and-skip silently masks broken local setups as "skipped"; tagged-and-excluded
makes both the opt-in and the failure mode explicit.

The integration test targets a **local** model — Ollama, LM Studio, vLLM, or any
OpenAI-compatible local endpoint. Provider/model are env-var-configurable so any
contributor with a local LLM stack can run them. Paid-API coverage, if added, is
under its own tag (`:paid_llm`) — never the same `:e2e` test wired to a different
provider.

### 9. Livebook — model spec is a configurable input

A new livebook at `guides/llm-agent.livemd` builds a minimal end-to-end agent:
defines two `Jido.Action` modules as tools, defines a regular `Jido.Agent` with
`Jido.AI.ReAct.schema/1` and `signal_routes/0`, starts it under `Jido.AgentServer`,
calls `Jido.AI.ask_sync/2`, shows the answer, and inspects the conversation via a
projecting selector (no full-state reads — ADR 0021).

The rule for the livebook is one thing: **the model spec is a configurable
`Kino.Input` at the top of the livebook.** The reader picks the provider —
Anthropic, OpenAI, Groq, a local endpoint, whatever ReqLLM supports. The livebook
does not hard-code a provider.

A sensible default for the input (e.g. local Gemma) is a separate, secondary
choice so cells run on first open. Readers without that local stack swap the input
to whatever they have. The default is a UX nicety, not part of the rule.

## Consequences

- **Public API gains `Jido.AI.*`.** ~10–12 new modules. Each is small (most under
  200 LOC). The biggest port is `Jido.AI.ToolAdapter` (~330 LOC verbatim from
  `jido_ai`); the slice/actions/directives plus helpers are ~600 LOC together.

- **`req_llm` joins jido's runtime deps.** Plus its own transitive dependencies
  (`req`, `jason`, etc.). For a non-AI user, the cost is some compile time and a
  few hundred KB of BEAM bytecode.

- **`jido_ai` users have a migration path, not a runtime upgrade.** They keep
  using `jido_ai` until they want to migrate. A migration guide ships once v1 is
  stable. The two packages have different reasoning catalogues, different runtime
  guarantees, and are not API-compatible — that's fine; one is the new architecture,
  the other is the old. We don't ship shims.

- **No streaming, no checkpoint tokens, no per-agent concurrency in v1.** Each is
  a substantial design decision with its own tradeoffs; v1 picks the smallest API
  that's still useful: cast a query, await a result.

- **Signal-driven loop has higher latency floor than a coordinator task.** Each
  LLM-call → response → tool-exec → response cycle hits the agent server's signal
  router twice. For a typical 4–5-iteration loop that's 8–10 router hops. The hops
  are local (within-VM) and add microseconds; the LLM call itself is hundreds of
  ms. The signal-driven shape's cost is negligible relative to the LLM and gives
  ADR-019/021 conformance for free.

- **The agent module is generic; the slice carries all LLM knowledge.** The
  user's `use Jido.Agent` line declares no LLM concepts beyond `path: :ai` and the
  slice's metadata. Composability is straightforward: add a memory slice, an
  identity slice, observability middleware — all in the same agent — without any
  AI-specific macro chain.

- **No standalone synchronous `ReAct.run/2` runner ships in v1.** The slice IS the
  ReAct strategy. A one-off REPL/script user spins up an agent server, calls
  `Jido.AI.ask_sync/3`, lets the supervisor clean up. That's the same path the
  livebook uses; there is no separate synchronous API to maintain. Task 0022's
  synchronous primitive is retired by task 0030.

- **Compensations, retries, and idempotency for tool calls inherit from
  `Jido.Exec`'s existing behaviour.** Tool exec is `Jido.Exec.run/4`; retries,
  timeouts, compensation hooks come from the action's configuration. v1 does not
  add an LLM-specific retry layer.

- **Integration tests run on the operator's local LLM.** The `:e2e` tag is the
  opt-in. If LM Studio / Ollama is down on the dev's machine, the test fails when
  they include the tag — not silently skipped. CI runs `mix test` (default,
  excludes `:e2e`) and never touches a paid API.

## Alternatives considered

**`use Jido.AI.Agent` macro that owns model/tools/system_prompt at compile time.**
This was the v1 of this ADR (and the v1 implementation in task 0023). The agent
macro carried LLM-specific config, the slice was attached as the agent's own
through macro internals, and a placeholder `model:` was needed to instantiate the
struct before per-call overrides could land. The agent module ended up knowing
about LLM concerns it should not own; the slice ended up not really being
configurable — its config flowed from the agent macro instead of from where it
naturally lives. Replaced.

**Pull slice metadata into `use Jido.Agent` via `path:` / `schema:` / `signal_routes:`.**
This was v2. The agent module wrote `path: :ai, schema: Jido.AI.ReAct.schema(...)`,
`signal_routes: Jido.AI.ReAct.signal_routes()` — the slice's schema function
returned a parameterized Zoi schema baking the LLM config into defaults. Two
problems: the agent's macro still mentioned `:ai` and the slice's schema/routes
(slice internals leaking into the agent), and the design only worked when the
AI slice was the agent's *own* slice (no composition with other agent state).
Replaced by §6 v3, which uses a framework-level `slices:` attachment so the
agent module declares nothing about the slice's internals.

**Slice attached as a plugin (`plugins: [Jido.AI.ReAct]`).** A `use Jido.Plugin`
module is `Slice + Middleware`. The ReAct slice doesn't need a middleware half.
Putting a bare slice in `plugins:` works today only because the validation is
weak (task 0029 fixes that). Even if it worked, the plugin's `route_prefix` would
prepend the slice's name to its routes, producing `"ai.ai.react.ask"` instead of
`"ai.react.ask"`. The natural bucket for bare slices is `slices:` (added in
task 0032), which mounts the slice without prefixing.

**Build a thin `Jido.AI.Model` behaviour and write per-provider HTTP clients
ourselves.** Pros: smaller dep list. Cons: duplicates ReqLLM's provider catalogue,
wire-format marshalling, tool shape conversions, and streaming infrastructure for
no real gain. The "avoid the dep" framing was a shortcut around the actual work
of porting the LLM-agent code we already have. Rejected.

**Port `jido_ai`'s `ReAct.Runner` coordinator task as-is.** Pros: existing code,
already tested under load. Cons: violates ADR 0019 (the coordinator inlines side
effects), violates ADR 0021 (the runner threads full state and uses internal
selectors that defeat the projection discipline), and brings ~5,900 LOC including
streaming, checkpoint tokens, pending-input servers, request transformers, FSM
strategy, and worker delegation that v1 doesn't need. Re-implementing the loop
signal-driven is ~600 LOC and is the architecture jido has already decided on.

**Inline as `Jido.LLM.*` instead of `Jido.AI.*`.** Marginal naming preference.
`Jido.AI.*` matches `jido_ai` and the existing community vocabulary; renaming for
naming-purity reasons would mean every migration mention has to explain the
rename. Not worth the friction.

**Skip ReAct in v1; ship just the tool adapter and a thin LLM-call action.**
That's "a ReqLLM wrapper packaged with jido", not "an LLM agent framework". The
loop is the value; without it users still build their own runtime. We commit to
ReAct as the v1 reasoning shape and add others (CoT, ToT, etc.) only behind their
own ADRs.

**Express the LLM agent purely as middleware on `Jido.Agent`.** Middleware runs
synchronously per signal and would make the LLM call inline — same problem as the
coordinator task. ReAct needs side effects out of the synchronous path. The slice +
custom directives + signal routes shape is the right one.

**Make ReAct concurrent (multiple runs per agent) in v1.** Concurrency interacts
with the slice (per-run state needs separation), the agent's signal ordering, and
the public `ask`/`await` contract. Out of scope for v1; the single-run rejection
makes the failure mode explicit.

**Keep the synchronous `Jido.AI.ReAct.run/2` runner alongside the slice.** Two
implementations of "the loop" would diverge, and `run/2` violates ADR 0019 anyway
(it runs side effects synchronously). The slice is the only ReAct in v1.

**Probe-and-skip integration tests on a missing local endpoint.** Silent skips
mask broken local setups. Tagged-and-excluded makes both opt-in and failure
explicit.

**Hard-code a provider in the livebook.** Excludes readers using other providers.
The rule is configurable; a sensible default is a UX nicety on top.

## Revision history

- **v3.1 (2026-04-28, §7 amended during task 0030 implementation)** —
  collapsed the §7 surface from `ask/3` + `await/2` + `ask_sync/3` +
  `%Jido.AI.Request{}` to `ask/3` + `ask_sync/3`. The `await/2` /
  `Request{}` pair was an artifact of bundling subscribe + cast into
  `ask/3` and handing the caller a handle. That design opinionated the
  subscription's filter (`:completed` / `:failed` only); real consumers
  want intermediate signals — tool-call notifications, streaming
  tokens, reasoning steps. Subscriptions are now out of band: `ask/3`
  fire-and-forgets via `Jido.AgentServer.call/4` and returns the minted
  `request_id`; `ask_sync/3` is the convenience that subscribes
  internally for the terminal transition. Run-config resolution (the
  per-call → slice fallback) lives entirely in `Jido.AI.Actions.Ask`;
  `ask/3` reads no slice state. Action-level rejections (`:busy`,
  `:no_model`) come back through `call/4`'s chain-error path.

- **v3 (2026-04-28, second revision)** — replaced the §6 v2 design (slice
  metadata pulled into `use Jido.Agent` via `path:` / `schema:` /
  `signal_routes:`) with proper slice attachment via a new framework option
  `slices:` (added in task 0032). The agent module no longer declares
  *anything* about the AI slice — its `path`, schema, routes, and actions all
  live on `Jido.AI.ReAct` and are wired in by the framework when the user
  writes `slices: [{Jido.AI.ReAct, model: ..., tools: ...}]`. The v2 design
  still bled slice internals into the agent macro; v3 fixes that.

- **v2 (2026-04-28)** — replaced the `use Jido.AI.Agent` macro design (§6 v1)
  with a slice-composition design where the agent's *own* slice is the AI
  slice (`path: :ai`, `schema: Jido.AI.ReAct.schema(...)`, `signal_routes:
  Jido.AI.ReAct.signal_routes()`). Added §7 (`Jido.AI` namespace helpers).
  Rewrote §8 (tests are tagged, not probed). Retired the standalone
  `Jido.AI.ReAct.run/2` synchronous runner. Replaced by v3 because the agent
  macro still ended up declaring slice internals.

- **v1 (2026-04-27)** — original ADR. Proposed `use Jido.AI.Agent` macro,
  `plugins: [Jido.AI.Slice]`, probe-and-skip integration tests. Implemented
  in task 0023 commit `4f4532e`; retired by v2 / v3.
