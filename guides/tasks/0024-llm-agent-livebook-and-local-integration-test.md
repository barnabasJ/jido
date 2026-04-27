---
name: Task 0024 — Livebook with configurable model + local-LLM integration test + docs index
description: Ship the user-facing teaching artifact (`guides/llm-agent.livemd`) with the model spec exposed as a Livebook input (the **rule**). Add the integration test that targets a local LLM with probe-and-skip (the **rule**). Update docs index.
---

# Task 0024 — Livebook with configurable model + local-LLM integration test + docs index

- Implements: [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §7, §8.
- Depends on: [task 0023](0023-llm-agent-slice-plugin.md).
- Blocks: nothing.
- Leaves tree: **green**.

## Two rules, two artifacts

This task carries two distinct rules — keep them separate, don't
conflate.

**Rule 1 — Integration test: local.** The integration test runs
against a local LLM endpoint. Not "configurable", not "local with a
paid-API escape hatch." Local. If the local endpoint isn't reachable,
the test **skips**. Anyone with Ollama running can run the test;
everyone else sees a skip. Paid-API coverage, if ever added, is a
separate test under a separate tag.

**Rule 2 — Livebook: configurable.** The livebook exposes the model
spec as a `Kino.Input` at the top of the file. The reader picks the
provider — Anthropic, OpenAI, Groq, local, whatever ReqLLM supports —
by typing into the input. The rule is "configurable", not "configurable
with a local default" — picking what the input defaults to is a
secondary implementation choice, separate from the rule.

## Goal

After this commit:

1. A user opens `guides/llm-agent.livemd` and runs the cells
   top-to-bottom. The model spec is a `Kino.Input` at the top. The
   reader chooses the provider; the livebook itself is provider-neutral.

2. `mix test --include local_llm` runs an end-to-end integration test
   against the local LLM. If the local endpoint isn't reachable on a
   probe, the test skips with a friendly message (not a failure).

3. `mix docs` shows the livebook in the sidebar under a new "AI Agents"
   section. ADR 0022 is indexed in `guides/adr/README.md`.

This task is the "make it findable, runnable, and verified end-to-end"
pass. No new runtime code; only a livebook, an integration test, and
documentation wiring.

## Files to create

### `guides/llm-agent.livemd`

Six-cell quickstart livebook.

**Cell 1 — Setup + model input.**

The model spec is a `Kino.Input`. The livebook is configurable by
construction; the reader picks the provider. The input has a default
value so first-open is runnable, but the default is a UX nicety, not
the rule.

```elixir
Mix.install([{:jido, path: ".."}, {:kino, "~> 0.13"}])

model_input =
  Kino.Input.text("Model spec (any ReqLLM-supported)",
    default: "google:gemma-3-27b@http://localhost:11434/v1")

Kino.Markdown.new("""
## LLM Agent Quickstart

The model spec above is editable — pick whatever provider you have
access to. Examples:

- `anthropic:claude-haiku-4-5-20251001` (needs `ANTHROPIC_API_KEY`)
- `openai:gpt-5` (needs `OPENAI_API_KEY`)
- `groq:gemma2-9b-it` (needs `GROQ_API_KEY`)
- a local endpoint via Ollama / vLLM (no key)

For the local-Gemma default, install once:

    ollama pull gemma3:27b
    ollama serve
""")
```

(Confirm against `req_llm`'s actual model-string format for local
endpoints. If the convention is `openai:<model>` with a custom
`base_url:` opt rather than the `@<url>` suffix, adjust the default
spec and the agent definition's `model:` opt accordingly. The default
value is implementer's choice; the rule is that the input exists.)

**Cell 2 — Define tool actions.**

```elixir
defmodule LB.Add do
  use Jido.Action,
    name: "add",
    description: "Adds two integers and returns their sum.",
    schema: [a: [type: :integer, required: true],
             b: [type: :integer, required: true]]

  def run(%{data: %{a: a, b: b}}, slice, _opts, _ctx) do
    {:ok, slice, [], %{result: a + b}}
  end
end

defmodule LB.Multiply do
  use Jido.Action,
    name: "multiply",
    description: "Multiplies two integers and returns their product.",
    schema: [a: [type: :integer, required: true],
             b: [type: :integer, required: true]]

  def run(%{data: %{a: a, b: b}}, slice, _opts, _ctx) do
    {:ok, slice, [], %{result: a * b}}
  end
end
```

**Note on action return shape.** Confirm against the post-task-0011
tagged-tuple contract (ADR 0018) what the action's return *value* is —
the runner needs the `result: a + b` to come back from `Jido.Exec.run/4`
in a way the `ToolExec` directive executor can pick up. If actions
return `{:ok, new_slice, directives}` only (no extra "result" channel),
the convention for tools is to encode the result *as* the slice
mutation, then have the `ToolExec` executor read the produced slice
diff. Walk through `Jido.Exec.run/4`'s output shape with task 0022's
runner before finalizing this cell so the demo teaches the right
pattern.

**Cell 3 — Define the agent.**

```elixir
defmodule LB.MathAgent do
  use Jido.AI.Agent,
    name: "math",
    description: "Does math with tools.",
    model: Kino.Input.read(model_input),
    tools: [LB.Add, LB.Multiply],
    system_prompt: "Use the available tools to compute step-by-step. Show your work briefly.",
    max_iterations: 6
end
```

(If the `use Jido.AI.Agent` macro requires a literal model spec at
compile time, take the `Kino.Input.read/1` value out of the macro and
into runtime `ask/3` opts instead, with the macro getting a placeholder.
Match what the macro accepts per task 0023.)

**Cell 4 — Start it and ask a question.**

```elixir
{:ok, pid} = Jido.AgentServer.start(agent: LB.MathAgent)

{:ok, answer} = LB.MathAgent.ask_sync(pid, "What is (5 + 7) * 2?", timeout: 60_000)

Kino.Markdown.new("**Answer:** #{answer}")
```

**Cell 5 — Inspect the conversation.**

```elixir
{:ok, ctx} =
  Jido.AgentServer.call(pid, fn s -> {:ok, s.agent.state.ai.context} end)

ctx
|> ReqLLM.Context.to_messages()
|> Enum.with_index()
|> Enum.map(fn {msg, i} ->
  "##{i}. **#{msg.role}**: #{format_content(msg)}"
end)
|> Enum.join("\n\n")
|> Kino.Markdown.new()
```

(`format_content/1` is a helper in the cell that handles tool_use /
tool_result content blocks. ReqLLM's message shape is the contract.)

The selector `fn s -> {:ok, s.agent.state.ai.context} end` is a
**projecting selector** — it returns just the context, not the whole
state. ADR 0021 forbids `fn s -> {:ok, s} end`; this is the compliant
shape.

**Cell 6 — Stop the agent.**

```elixir
Jido.AgentServer.stop(pid)
```

The livebook does not use `Process.sleep` (per task 0019 / ADR 0021).
`ask_sync/3` already handles the wait via subscription internally.

### `test/jido/ai/integration/local_llm_test.exs`

Tagged `@moduletag :local_llm`. Excluded from default `mix test` via
`mix.exs` test alias.

Setup: probes the local endpoint (HTTP HEAD to `http://localhost:11434`
or whatever is configured via `LOCAL_LLM_URL` env var). If the probe
fails or times out under 1 second, the test is **skipped** with a
descriptive message ("local LLM endpoint not reachable; start Ollama or
set LOCAL_LLM_URL"). Not a failure.

```elixir
defmodule Jido.AI.Integration.LocalLLMTest do
  use ExUnit.Case, async: false
  @moduletag :local_llm
  @moduletag timeout: 60_000

  setup_all do
    url = System.get_env("LOCAL_LLM_URL", "http://localhost:11434")
    case probe(url) do
      :ok -> {:ok, url: url}
      {:error, reason} ->
        IO.puts("\nSkipping :local_llm tests — local LLM endpoint not reachable (#{inspect(reason)})")
        IO.puts("To run: `ollama pull gemma3` && `ollama serve`, then `mix test --include local_llm`\n")
        :ignore
    end
  end

  defmodule Add do
    use Jido.Action, ...
  end

  defmodule Multiply do
    use Jido.Action, ...
  end

  defmodule MathAgent do
    use Jido.AI.Agent,
      name: "local_llm_math",
      model: # ... read from env or default to local gemma spec,
      tools: [Add, Multiply]
  end

  test "local model resolves a multi-tool query", %{url: _url} do
    {:ok, pid} = Jido.AgentServer.start(agent: MathAgent)
    {:ok, answer} = MathAgent.ask_sync(pid, "What is 5 + 7 * 2?", timeout: 50_000)

    assert is_binary(answer)
    assert answer =~ ~r/\b19\b/
  end

  defp probe(url), do: # ... HTTP HEAD with 1s timeout
end
```

The model name and provider string for local Gemma are pinned in the
test (e.g., `"google:gemma-3-27b@http://localhost:11434/v1"` or whatever
ReqLLM's local-endpoint syntax requires). Document the pinned model in
a comment so future maintainers know to update it when Gemma releases
new versions.

The test is **deliberately minimal**: one query, one assertion. The
unit tests in `test/jido/ai/agent_test.exs` (Mimic-stubbed) cover the
loop's edge cases. This test is the wire-shape smoke check.

A paid-API smoke check is **out of scope for this task** — the
integration test is local. If a paid-API smoke is ever wanted later,
it's a separate task and a separate test file under its own tag
(`:paid_llm`).

## Files to modify

### `mix.exs`

Update test alias to exclude `:local_llm`:

```elixir
test: "test --exclude flaky --exclude local_llm"
```

(Match the existing alias's shape; this is additive. `:paid_llm` is
not added — there's no paid-LLM test in v1.)

Add the livebook to `extras` and `groups_for_extras`:

```elixir
extras: [
  ...,
  {"guides/llm-agent.livemd", title: "LLM Agent Quickstart"},
  ...
]

groups_for_extras: [
  ...,
  "AI Agents": [
    "guides/llm-agent.livemd"
  ],
  ...
]
```

The "AI Agents" group goes between "Coordination" and "Operations" in
the existing structure.

### `guides/tasks/README.md`

Update the table to include 0021-0024 (rows already added in the
previous draft; trim to 4 rows now and confirm) and the dependency
block:

```
| [0021](0021-reqllm-dep-and-tool-adapter.md) | Add `req_llm` dep + port `Jido.AI.ToolAdapter` + port `Jido.AI.Turn` | **green** | [ADR 0022](../adr/0022-llm-agents-inlined-jido-ai-namespace.md) §2 §4 |
| [0022](0022-react-runtime-pure.md) | `Jido.AI.ReAct` synchronous loop over `ReqLLM.Generation`, no agent dep | **green** | ADR 0022 §5 (loop logic) |
| [0023](0023-llm-agent-slice-plugin.md) | `Jido.AI.Agent` macro + slice + actions + custom directives (signal-driven envelope) | **green** | ADR 0022 §5 §6 |
| [0024](0024-llm-agent-livebook-and-local-integration-test.md) | Configurable livebook (default local Gemma) + local-LLM smoke test + docs index | **green** | ADR 0022 §7 §8 |
```

Dependency block:

```
0019 ← 0021              (additive — req_llm dep + Jido.AI.* leaf modules)
0021 ← 0022              (ADR 0022 — ReAct synchronous loop uses ToolAdapter + Turn)
0022 ← 0023              (ADR 0022 — signal-driven agent envelope wraps the synchronous loop)
0023 ← 0024              (ADR 0022 — livebook + local-LLM integration test)
```

### `guides/adr/README.md`

ADR 0022 row (already added in the previous draft) — confirm the row is
still present and the description matches the rewritten ADR:

```
| [0022](0022-llm-agents-inlined-jido-ai-namespace.md) | LLM agents inlined under `Jido.AI.*` on top of `req_llm`; signal-driven ReAct | Proposed | Pending |
```

Update Status / Implementation in the ADR header itself (in this
commit) to **Accepted** / **Complete** once the implementation tasks
0021-0023 have all landed and 0024 is on the verge of merging. The
`Related commits / PRs:` line gets the SHAs from 0021-0024.

### `README.md` (optional)

Add a 4-line "LLM Agents" section pointing at `guides/llm-agent.livemd`
and the `Jido.AI.Agent` module. Skip if README has no natural home for
it.

## Files to delete

None.

## Acceptance

- `mix run scripts/verify_livemd.exs guides/llm-agent.livemd` evaluates
  top-to-bottom without raising **when a local LLM is available**.
  Without one, the verifier should skip Cell 4 (the `ask_sync/3` call)
  with a `Kino.Markdown` warning rather than fail; alternatively, the
  verifier supports a `:skip_if` mechanism for local-network cells —
  match what `verify_livemd.exs` already supports per task 0019.
- `mix test` (default) is green; `:local_llm` and `:paid_llm` tagged
  tests are excluded.
- `mix test --include local_llm` is green when a local LLM endpoint is
  reachable; skips with a friendly message otherwise.
- The livebook doesn't use `Process.sleep` (task 0019 / ADR 0021).
- The livebook doesn't write `fn s -> {:ok, s} end` (ADR 0021); the
  inspection cell uses a projecting selector.
- ADR 0022 is updated in `guides/adr/README.md` and the ADR's own
  status/implementation flips to Accepted/Complete in this commit.
- Tasks 0021-0024 indexed in `guides/tasks/README.md`.
- `mix docs` builds without warnings; "AI Agents" appears in the
  sidebar.
- `mix dialyzer` clean.
- `mix credo --strict` clean.
- `mix format --check-formatted` clean.

## Out of scope

- **Paid-provider integration test as part of this task.** The
  integration test is local. Paid-API coverage, if ever added, is a
  separate test file under a separate tag — its own task.
- **Hard-coding the livebook to a specific provider.** The livebook
  is configurable. The reader picks. (The default value of the input
  is a separate implementation choice; we've picked a local-Gemma
  default for first-open UX, but the rule is "configurable", not
  "defaults to local.")
- **A second livebook for the synchronous `Jido.AI.ReAct.run/2` API.**
  The agent quickstart covers the common case; the synchronous API is
  documented in moduledocs and can get its own livebook later if
  there's demand.
- **A `Jido.AI.Agent` cookbook with multiple recipes.** One livebook
  is enough for v1.
- **Migration guide from `jido_ai`.** Defer to a separate task once
  v1 stabilizes.
- **CI runner with a hosted Gemma instance.** v1 doesn't run the
  integration test in CI. If we want CI coverage, that's a separate
  decision (vLLM container in the CI image, etc.).
- **Coverage of every ReqLLM provider.** The livebook documents three
  examples (Anthropic, OpenAI, Groq); ReqLLM has 25+ providers. We
  don't enumerate them in the livebook — point at ReqLLM's docs.

## Risks

- **Local Gemma model name drift.** Ollama image tags
  (`gemma3:27b`, `gemma2:9b`, etc.) update over time. Document the
  known-working name in the livebook and the integration test as a
  comment, with a note that newer Gemma versions should work with the
  same wire shape.

- **ReqLLM's local-endpoint syntax.** ReqLLM may use one of:
  - `openai:gemma3@http://localhost:11434/v1` (suffix syntax)
  - `{provider, base_url: "http://localhost:11434/v1", model: "gemma3"}` (struct)
  - a dedicated `:ollama` provider
  Confirm against `req_llm`'s docs at port time. The livebook example
  needs to be a working spec, not pseudo-syntax. If the syntax is
  awkward, consider exposing a small `Jido.AI.local_model/1` helper —
  but only if the resulting spec is genuinely confusing, not for
  ergonomics alone.

- **Verifier hangs on unreachable local endpoint.** If the verifier
  evaluates Cell 4 and the local endpoint isn't reachable, ReqLLM's
  HTTP call will hang until its timeout (typically 30-60s). Either
  the verifier needs a `skip_if`-style annotation on the cell, or
  Cell 4 has a probe-first guard. Match what `verify_livemd.exs`
  supports per task 0019. If neither, document that running the
  verifier requires a local LLM running.

- **Test flakiness from local model slowness.** First-token latency on
  a cold Ollama can be 5+ seconds; combined with multi-iteration ReAct
  this can hit 60s. The test's `timeout: 50_000` and the ExUnit
  `@moduletag timeout: 60_000` give some headroom but can still flake
  on a cold machine. Document the warm-up step (`ollama run gemma3
  "hello"` once before running the test).

- **Anthropic/paid-API tests in CI.** Don't add them as default. The
  default test suite must run without secrets, without paid API
  access, and without external network. Adding paid-API gating in
  CI is a deliberate decision (cost, secrets) that's a separate ADR
  if it's ever wanted.

- **`Kino.Input.read/1` in macro arguments.** If `use Jido.AI.Agent`
  needs the model at compile time, reading the input value won't work
  there — the agent module is compiled before the user types into the
  input. Either the macro accepts runtime values for `model:` (passed
  through to `ask/3` opts each call), or the livebook reads the input
  inside `ask/3` rather than in the agent definition. Match what
  task 0023's macro contract supports.
