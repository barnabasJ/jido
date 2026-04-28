---
name: Task 0031 — Livebook with configurable model + tagged-and-excluded integration tests
description: Ship `guides/llm-agent.livemd` with the model spec as a `Kino.Input` (configurable, the reader picks). Add agent-level integration tests under the `:e2e` tag — excluded by default, run via `mix test --include e2e`, no probe-and-skip. Update the docs index. Supersedes task 0024.
---

# Task 0031 — Livebook with configurable model + tagged-and-excluded integration tests

- Implements: [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) v3.1 §8, §9.
- Depends on: [task 0030](0030-llm-agent-slice-composition-refactor.md).
- Supersedes: [task 0024](0024-llm-agent-livebook-and-local-integration-test.md) (same goal, three rules updated to match ADR v3.1: tagged-not-probed, slice-composition agent shape, `ask/3` + `ask_sync/3` only — no `await/2`/`Request{}`).
- Blocks: nothing.
- Leaves tree: **green**.

## Two rules, two artifacts

Keep them separate; do not conflate.

**Rule 1 — Integration tests: tagged, not probed.** The agent-level integration
tests are tagged `:e2e`. They are **excluded by default** in `test_helper.exs`'s
`ExUnit.configure(exclude: [...])`. To run them: `mix test --include e2e`.

There is **no probe-and-skip**. The tests do not check whether the local LLM is
reachable and silently skip on failure. If the operator opted in via
`--include e2e` and the endpoint is down, the test fails. That's the right
signal — silent skips mask broken local setups as "passing."

The tests target a **local** model — Ollama, LM Studio, vLLM, or any
OpenAI-compatible local endpoint. Provider/model are env-var-configurable so a
contributor's local stack drives them. Paid-API coverage, if ever added, is a
separate tag (`:paid_llm`); never the same `:e2e` test wired to a different
provider.

**Rule 2 — Livebook: configurable.** The livebook exposes the model spec as a
`Kino.Input` at the top. The reader picks the provider — Anthropic, OpenAI, a
local OpenAI-compatible endpoint (LM Studio / Ollama / vLLM at
`http://localhost:1234/v1`), whatever ReqLLM supports — by selecting from the
input. The rule is "configurable," not "configurable with a local default."
Picking the input's default is a secondary, separate UX choice.

## Goal

After this commit:

1. A reader opens `guides/llm-agent.livemd` and runs cells top-to-bottom. The
   model spec is a `Kino.Input` at the top. The agent is a regular
   `use Jido.Agent` composing `Jido.AI.ReAct` via the framework's `slices:`
   option (`slices: [{Jido.AI.ReAct, model: ..., tools: ..., system_prompt:
   ..., max_iterations: ..., llm_opts: ...}]`). `Jido.AI.ask/3` and
   `Jido.AI.ask_sync/3` are the reader-facing calls. No `Jido.AI.Agent`
   macro, no `Jido.AI.await/2`, no `%Jido.AI.Request{}` appears anywhere.

2. The headline cell drives **subscription-driven streaming of ReAct
   steps**: a `Kino.Input.text` for the question, a `Kino.Control.button`
   for submit, and a `Kino.Frame` rendering each step (thinking, tool
   calls, tool results, final answer) as the run progresses. The
   subscription is the caller's — set up via `Jido.AgentServer.subscribe/4`
   with a pure projecting selector before `Jido.AI.ask/3` fires. No
   `Process.sleep`, no polling — the receive loop drains dispatches until
   the slice settles `:completed` or `:failed`, with a generous deadline
   that surfaces as a clear "timed out" message rather than silent hang.

3. `mix test --include e2e` runs the agent-level integration tests against the
   local LLM. With the operator's local stack up, all tests pass. With it
   down, the relevant tests fail (not skip).

4. `mix docs` shows the livebook in the sidebar under a new "AI Agents"
   section.

This task is "make it findable, runnable, verified end-to-end." No new runtime
code; only a livebook, optional additional tagged tests, and documentation
wiring.

## Files to create

### `guides/llm-agent.livemd`

Cell breakdown (titles approximate; the livebook may collapse adjacent
cells where the prose flows naturally).

**Setup.** `Mix.install` with `{:jido, path: ...}` and `{:kino, "~> 0.16"}`,
plus a small `Demo.Jido` OTP harness (mirroring `call-cast-await-subscribe.livemd`'s
setup) so the livebook has a Jido instance to start agents under.

**Model + API key.** A `Kino.Input.select/2` with a small set of provider
options:

  * Local OpenAI-compatible endpoint (LM Studio / Ollama / vLLM at
    `http://localhost:1234/v1`) — sensible default so the cells run on
    first open if a local stack is up.
  * Anthropic — needs API key.
  * OpenAI — needs API key.

A separate `Kino.Input.password/1` for the API key (defaulting empty;
local endpoints don't need one).

**Tool actions.** Two `use Jido.Action` modules inline (e.g. `Add` and
`Multiply`). The slice exposes both to the LLM via `ReqLLM.Tool` adapters.

**Agent module.** A regular `use Jido.Agent` that reads the input values
and attaches `Jido.AI.ReAct` via `slices: [{Jido.AI.ReAct, model: ...,
tools: ..., system_prompt: ..., max_iterations: ..., llm_opts: [api_key:
...]}]`. The agent module declares no AI internals.

**Streaming output via subscription.** A small `Demo.Streamer` module
holding the projecting selector + a `render/3` function that maps signal
type + projection to a Kino.Markdown line, plus a `drain/3` receive loop
that runs through the subscription dispatches until terminal.

**Run cell — question + button + live output.** This is the headline.
A `Kino.Input.text` for the question, a `Kino.Control.button("Ask")` for
submit, and a `Kino.Frame` for live output. Wiring:

  * Subscribe to `"ai.react.**"` with a pure projecting selector that
    returns `{status, iteration, pending_tool_calls, last_tool_message,
    result, error}`. Default subscribe dispatch sends
    `{:jido_subscription, sub_ref, %{signal_type: type, result: {:ok,
    projection}}}` to the calling process.
  * On click: `Jido.AI.ask(pid, question)` to get the request_id, then
    `drain/3` reads dispatches and `Kino.Frame.append/2`s a step line for
    each:
      - "Thinking…" on `ai.react.ask`.
      - "Calling tool: <name>(<args>)" on `ai.react.llm.completed` with
        non-empty `pending_tool_calls`.
      - "Tool result: <name> → <content>" on `ai.react.tool.completed`.
      - The final answer on `ai.react.llm.completed` with `:completed`.
      - The error term on `ai.react.failed`.
  * No `Process.sleep`, no polling. Pure receive on the subscription's
    dispatches with a deadline (60s) that renders "timed out" rather than
    hanging silently.

This cell explicitly demonstrates that `ask/3` is fire-and-forget
(returns `{:ok, request_id}`), the subscription is the caller's, and the
framework imposes no opinion on what to filter for. This is "streaming
output via subscription" at the **signal level** (each ReAct step), not
the token level (the slice doesn't do token streaming today; the cell's
prose says so).

**`ask_sync/3` contrast (optional).** Same agent, same question, but
`Jido.AI.ask_sync/3` returns just the final text. Two paths, same agent —
pick the shape that fits your use case.

### `test/jido/ai/react_e2e_test.exs` (already shipped in task 0030)

Four tagged-`:e2e` tests already cover the agent against a real local
LLM, including:

1. Single-turn final answer (no tools).
2. Tool-calling round trip with `TestEcho`.
3. Numeric tool call with `TestAdd`.
4. Out-of-band subscription observing every intermediate signal — the
   canonical pattern the livebook mirrors in UI form
   (`drain_until_completed/3`).

Task 0031 may add additional tagged coverage if the livebook surfaces
something new (e.g. paid-API coverage under a separate `:paid_llm` tag —
never the same `:e2e` test wired to a different provider, per ADR 0022
§8). It does not need to ship new e2e tests.

Configurable via env vars (matching the existing convention):

- `LMSTUDIO_BASE_URL` (default `http://localhost:1234/v1`)
- `LMSTUDIO_MODEL`    (default `google/gemma-4-26b-a4b`)
- `LMSTUDIO_API_KEY`  (default `lm-studio` — LM Studio ignores it)

## Files to modify

### `test/test_helper.exs`

Confirm `:e2e` is in `ExUnit.configure(exclude: [...])`. Already true today;
this task verifies the opt-in is intact.

### `mix.exs` — docs

- Add a new "AI Agents" section to `groups_for_extras` containing
  `"guides/llm-agent.livemd"`.
- Add `{"guides/llm-agent.livemd", title: "LLM Agent — Quick Start"}` to
  `extras`.

### `guides/tasks/README.md`

Mark task 0031 row as **green**.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean (allowing the pre-existing `LLMDB.Model.t/0` warning).
- `mix test` clean — zero `warning:` lines.
- `mix test --include e2e` clean — zero `warning:` lines, the four
  agent-level tests pass against the operator's local LLM.
- `mix docs` builds without xref warnings; the livebook appears in the sidebar
  under "AI Agents".
- Manually opening `guides/llm-agent.livemd` and clicking Run runs all the
  cells top-to-bottom against the operator's local LLM with no edits, and
  the question-input cell streams ReAct steps live into the Kino.Frame.
- ADR 0019 / 0021 / 0022 v3.1 conformance: no polling in the livebook or the
  tests; no `Process.sleep` outside intentional fixture pauses; agent shape
  is the slice-composition pattern, not a `Jido.AI.Agent` macro; the
  user-facing API is `Jido.AI.ask/3` + `Jido.AI.ask_sync/3`, no
  `await/2`/`Request{}`.

## Out of scope

- A second livebook for one-off synchronous LLM calls. There is no
  `Jido.AI.ReAct.run/2` anymore (retired by task 0030). The agent path is the
  one path; one-off use is `Jido.AI.ask_sync/3` against an agent server you
  spin up and let go.
- **Token-level streaming** (per-token signals through
  `ReqLLM.Generation.stream_text/3`). v1 streams ReAct *steps* via the
  subscription — each LLM turn / tool call / tool result is one step.
  Token streaming is a separate design with its own ADR.
- A migration guide from `jido_ai`. Out of scope for v1 per ADR 0022.
- Paid-API integration tests. Separate tag (`:paid_llm`), separate task
  if/when needed.
- Multi-instance ReAct (two `Jido.AI.ReAct` slices on the same agent
  with `as: :sales` / `as: :support`). Task 0032 reserves the field;
  v1 doesn't wire it.

## Risks

- **The operator's local model may behave differently.** The two e2e tests
  target a small local model (default Gemma via LM Studio). If the operator's
  configured model is much smaller or much larger and answers very differently
  to the test prompts, the assertions may flap. Keep prompts narrow and
  assertions loose (`String.contains?(text, "11")`, not exact equality), and
  prefer prompts the model can answer in one or two LLM calls.

- **`mix test --include e2e` is now part of the local quality gate.** The
  project's working agreement is that the gate passes including e2e on the dev
  machine. The env vars are documented at the top of `react_e2e_test.exs` and
  in the ADR's §8 cross-reference so a contributor knows what to point at.

- **The livebook's default model spec.** The default points at a local
  OpenAI-compatible endpoint. Contributors with LM Studio / Ollama / vLLM
  installed and a compatible model loaded will get the default to "just
  work"; everyone else swaps the input. Keep the default-pick logic
  visible in the cell with a comment naming the rule that the input is
  the source of truth.

- **Subscription-driven streaming of ReAct steps.** This is the headline
  feature of the livebook and the closest thing v1 has to "streaming
  output." Make sure the cell's prose distinguishes signal-step
  streaming from token streaming — they're different things, and a
  reader expecting token-level deltas needs to know v1 doesn't do that.

- **`docs index` updates risk drifting from ADR file moves.** If a future ADR
  renumber happens, the `mix.exs` extras list needs updating. Keep the entries
  minimal and grouped so the maintenance surface is small.
