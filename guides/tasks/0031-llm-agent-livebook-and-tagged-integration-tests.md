---
name: Task 0031 — Livebook with configurable model + tagged-and-excluded integration tests
description: Ship `guides/llm-agent.livemd` with the model spec as a `Kino.Input` (configurable, the reader picks). Add agent-level integration tests under the `:e2e` tag — excluded by default, run via `mix test --include e2e`, no probe-and-skip. Update the docs index. Supersedes task 0024.
---

# Task 0031 — Livebook with configurable model + tagged-and-excluded integration tests

- Implements: [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) v2 §8, §9.
- Depends on: [task 0030](0030-llm-agent-slice-composition-refactor.md).
- Supersedes: [task 0024](0024-llm-agent-livebook-and-local-integration-test.md) (same goal, two rules updated to match ADR v2: tagged-not-probed, slice-composition agent shape).
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
`Kino.Input` at the top. The reader picks the provider — Anthropic, OpenAI,
Groq, a local endpoint, whatever ReqLLM supports — by typing into the input.
The rule is "configurable," not "configurable with a local default." Picking
the input's default is a secondary, separate UX choice.

## Goal

After this commit:

1. A reader opens `guides/llm-agent.livemd` and runs cells top-to-bottom. The
   model spec is a `Kino.Input` at the top. The agent is a regular
   `use Jido.Agent` composing `Jido.AI.ReAct.schema/1` and `signal_routes/0`.
   `Jido.AI.ask_sync/3` is the reader-facing call. No `Jido.AI.Agent` macro
   appears anywhere.

2. `mix test --include e2e` runs the agent-level integration tests against the
   local LLM. With the operator's local stack up, all tests pass. With it
   down, the relevant tests fail (not skip).

3. `mix docs` shows the livebook in the sidebar under a new "AI Agents"
   section. ADR 0022 (v2) is indexed in `guides/adr/README.md`.

This task is "make it findable, runnable, verified end-to-end." No new runtime
code; only a livebook, integration tests, and documentation wiring.

## Files to create

### `guides/llm-agent.livemd`

Six-cell quickstart livebook.

**Cell 1 — Setup + model input.** Mix install, ReqLLM key registration, and a
`Kino.Input.text/2` for the model spec. The default is a sensible local-LLM
spec (e.g. `"openai:google/gemma-4-26b-a4b"` against `http://localhost:1234/v1`,
since that matches the dev machine the project develops against), but the rule
is configurability — the reader can type any ReqLLM-supported spec.

**Cell 2 — Two tool actions.** Two minimal `Jido.Action` modules a model can
pick (`Add` and `Multiply`, or similar), defined inline. These are the
"tools" the slice will expose to the LLM.

**Cell 3 — Define the agent.** A regular `use Jido.Agent`, attaching
`Jido.AI.ReAct` via `slices: [{Jido.AI.ReAct, model: ..., tools: ...,
system_prompt: ..., max_iterations: ...}]`. The agent module mentions no AI
internals; the slice carries everything. This is the only thing the reader
needs to do to make an LLM agent — no custom macro, no plugin, no `path:`/
`schema:`/`signal_routes:` plumbing.

**Cell 4 — Start.** `Jido.AgentServer.start_link/1`. Returns the pid that the
helpers in `Jido.AI` accept.

**Cell 5 — Ask.** `Jido.AI.ask_sync(pid, "...")` and render the result. A
second cell shows a tool-using prompt so the reader sees the model picking a
tool and the agent running it.

**Cell 6 — Inspect.** A projecting selector (per ADR 0021) that returns the
slice's iteration count, status, and the conversation length. Demonstrates how
to read agent state without a full-state read.

Every wait inside the livebook is `ask_sync/3` (which `receive`s under the
hood). No `Process.sleep`. Per ADR 0021, no full-state reads.

### `test/jido/ai/agent_e2e_test.exs`

Agent-level integration tests, tagged `:e2e`. Each test:

1. Defines a regular `use Jido.Agent` test agent that attaches
   `Jido.AI.ReAct` via `slices: [{Jido.AI.ReAct, model: ..., tools: ..., system_prompt: ...}]`.
2. Starts it via `Jido.AgentServer.start_link/1` (using `JidoTest.Case`'s
   per-test Jido instance).
3. Calls `Jido.AI.ask/3` + `Jido.AI.await/2` (or `ask_sync/3`).
4. Asserts the result.

Cases:

1. **Single-turn final answer.** No tools, simple prompt, the model returns a
   final answer in one LLM call. Asserts text content, slice `:completed`,
   `iteration >= 1`.
2. **Tool round trip.** A tool is exposed; prompt asks the model to use it.
   Asserts `iteration >= 2`, slice context contains a `:tool` message.

These two are the floor. Add more if a regression bites; do not pre-build
exhaustive coverage that depends on model-specific quirks.

Configurable via env vars (matching the existing convention):

- `LMSTUDIO_BASE_URL` (default `http://localhost:1234/v1`)
- `LMSTUDIO_MODEL`    (default `google/gemma-4-26b-a4b`)
- `LMSTUDIO_API_KEY`  (default `lm-studio` — LM Studio ignores it)

## Files to modify

### `test/test_helper.exs`

Confirm `:e2e` is in `ExUnit.configure(exclude: [...])`. Already true today;
this task verifies the opt-in is intact.

### `mix.exs` — docs

- Add `"guides/llm-agent.livemd"` to `groups_for_extras` under a new
  "AI Agents" section.
- Add `{"guides/llm-agent.livemd", title: "LLM Agents"}` to `extras`.

### `guides/adr/README.md`

Add an entry for ADR 0022 (v2). The README isn't tracked here today; if it
exists, append the entry. If not, the docs index task is satisfied by the
`mix.exs` `groups_for_extras` change.

### `guides/tasks/README.md`

Add rows for tasks 0030 and 0031. Mark tasks 0022, 0023 as superseded by
0030 in their description column.

## Acceptance

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix credo --strict` clean.
- `mix dialyzer` clean (allowing the pre-existing `LLMDB.Model.t/0` warning).
- `mix test` clean — zero `warning:` lines.
- `mix test --include e2e` clean — zero `warning:` lines, two new agent-level
  tests pass against the operator's local LLM.
- `mix docs` builds without xref warnings; the livebook appears in the sidebar
  under "AI Agents".
- Manually opening `guides/llm-agent.livemd` and clicking Run runs all six
  cells top-to-bottom against the operator's local LLM with no edits.
- ADR 0019 / 0021 / 0022 v2 conformance: no polling in the livebook or the
  tests; no `Process.sleep` outside intentional fixture pauses; agent shape
  is the slice-composition pattern, not a `Jido.AI.Agent` macro.

## Out of scope

- A second livebook for one-off synchronous LLM calls. There is no
  `Jido.AI.ReAct.run/2` anymore (retired by task 0030). The agent path is the
  one path; one-off use is `Jido.AI.ask_sync/3` against an agent server you
  spin up and let go.
- Streaming / token-level UX in the livebook.
- A migration guide from `jido_ai`. Out of scope for v1 per ADR 0022.
- Paid-API integration tests. Separate tag, separate task if/when needed.

## Risks

- **The operator's local model may behave differently.** The two e2e tests
  target a small local model (default Gemma via LM Studio). If the operator's
  configured model is much smaller or much larger and answers very differently
  to the test prompts, the assertions may flap. Keep prompts narrow and
  assertions loose (`String.contains?(text, "11")`, not exact equality), and
  prefer prompts the model can answer in one or two LLM calls.

- **`mix test --include e2e` is now part of the local quality gate.** The
  project's working agreement is that the gate passes including e2e on the dev
  machine. Document the env vars at the top of `agent_e2e_test.exs` and in the
  ADR's §8 cross-reference so a contributor knows what to point at.

- **The livebook's default model spec.** The default points at the dev
  machine's local LM Studio config. Contributors on macOS / Linux with LM
  Studio installed will get the default to "just work" if they have a
  compatible model loaded; everyone else swaps the input. Keep the
  default-pick logic visible in cell 1 with a comment naming both the install
  command (`lms get ...` or equivalent) and the rule that the input is the
  source of truth.

- **`docs index` updates risk drifting from ADR file moves.** If a future ADR
  renumber happens, the `mix.exs` extras list and the README needs updating.
  Keep the entries minimal and grouped so the maintenance surface is small.
