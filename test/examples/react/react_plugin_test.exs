defmodule JidoExampleTest.ReactPluginTest do
  @moduledoc """
  Reference sketch: ReAct-as-plugin under the ADR 0011/0012 model.

  **This file is a design sketch, not an executable test.** It exists to
  demonstrate, ahead of implementation, that a ReAct-style LLM loop can be
  expressed cleanly using the primitives ADRs 0011 and 0012 propose — without
  introducing any new framework concept beyond the task-spawning directive
  (which is user-extensible per `guides/directives.md`).

  When Strategy is retired and the middleware behaviour lands, this file
  becomes an executable example test. Until then the body is commented-out
  pseudocode; the module compiles as an empty shell so the path lives in-tree
  and reviewers can read the intended shape.

  ## Primitives used

  - Plugin surface: `:react` slice, actions, `signal_routes/1`.
  - Self-dispatch: `%Jido.Agent.Directive.Emit{dispatch: nil}` falls back to
    `send(self(), {:signal, ...})` in `directive_executors`, re-entering the
    mailbox and re-routing via `signal_router`. Load-bearing for the loop.
  - Async tool calls: `%Jido.Agent.Directive.SpawnTask{task, timeout,
    on_success, on_timeout}` — a user-defined directive whose executor spawns
    a supervised task with a deadline and emits one of the two signals on
    outcome.
  - Middleware (ADR 0012): `Retry` for flaky tools, a custom `LoopTimeout`
    for the cumulative 30s budget, `LogErrors` for graceful failure.

  ## The loop, one iteration at a time

      signal "react.user_query" {query}
        → action ReAct.StartQuery
            writes :react.messages = [{:user, query}]
            emits %Directive.SpawnTask{
              task: fn -> LLM.call(messages) end,
              timeout: 20_000,
              on_success: "ai.llm_response",
              on_timeout: "ai.llm_timeout"
            }

      signal "ai.llm_response" {tool_calls | final_answer}
        → action ReAct.LLMEmitted
            branches:
              * tool_calls present:
                  appends assistant message to :react.messages
                  emits one %Directive.SpawnTask per tool_call
                    on_success: "tool.result"
                    on_timeout: "tool.timeout"
              * final_answer present:
                  emits %Directive.Emit{signal: "react.done", data: answer}
                  (user-facing terminal signal)

      signal "tool.result" {tool_id, result}
        → action ReAct.ToolCompleted
            appends tool message to :react.messages
            emits %Directive.SpawnTask (next LLM call — loops back)

      signal "tool.timeout" {tool_id}
        → action ReAct.ToolCompleted
            appends tool-timeout message so LLM sees the failure
            emits %Directive.SpawnTask (next LLM call)

  Each hop is a signal → route → action → directive → signal chain. No
  continuations, no mid-handler blocking, no strategy escape hatches.

  ## Plugin skeleton (pseudocode)

      defmodule Jido.Plugin.ReAct do
        use Jido.Plugin,
          name: "react",
          path: :react,
          schema: [
            messages: [type: {:list, :map}, default: []],
            step: [type: :atom, default: :idle],
            max_iterations: [type: :integer, default: 10],
            iteration: [type: :integer, default: 0]
          ],
          actions: [
            ReAct.StartQuery,
            ReAct.LLMEmitted,
            ReAct.ToolCompleted
          ]

        def signal_routes(_config) do
          [
            {"react.user_query", ReAct.StartQuery},
            {"ai.llm_response", ReAct.LLMEmitted},
            {"ai.llm_timeout",  ReAct.LLMEmitted},
            {"tool.result",     ReAct.ToolCompleted},
            {"tool.timeout",    ReAct.ToolCompleted}
          ]
        end
      end

  ## Agent wiring (pseudocode)

      defmodule MyReActAgent do
        use Jido.Agent,
          name: "react_agent",

          path: :domain,
          plugins:    [Jido.Plugin.ReAct],
          middleware: [
            Jido.Middleware.Logger,
            {Jido.Middleware.Retry, on: ["tool.result"], max: 3, backoff: :exp},
            {MyApp.Middleware.LoopTimeout, budget: 30_000},
            Jido.Middleware.LogErrors
          ]
      end

  ## Test walkthrough (pseudocode — becomes real asserts post-0011)

      test "ReAct loop: query → llm → tool → llm → final answer" do
        {:ok, agent} = start_agent(MyReActAgent)

        {:ok, ref} = Signal.Call.call(agent, signal("react.user_query",
          %{query: "what's the weather in Paris?"}))

        # LLM produces a tool_call for get_weather
        # → SpawnTask runs the tool (mock Weather.lookup/1)
        # → tool.result signal re-enters mailbox
        # → LLM called again with observation
        # → LLM produces final_answer
        # → react.done signal emitted

        assert_signal_emitted("react.done", timeout: 5_000,
          match: %{data: %{answer: answer}} when is_binary(answer))

        state = Agent.state(agent)[:react]
        assert state.step == :done
        assert length(state.messages) >= 3   # user + assistant + tool + assistant
      end

      test "tool timeout surfaces as an LLM observation, loop continues" do
        # Slow tool exceeds SpawnTask.timeout → on_timeout signal fires
        # → ToolCompleted records timeout → next LLM call includes error
        # → LLM can retry tool or give up with partial answer
        # No crash, no agent termination
      end

      test "global loop budget ends the loop with a stop directive" do
        # LoopTimeout middleware tracks elapsed time on each on_cmd entry
        # → after 30s emits %Directive.Stop{reason: :loop_budget_exceeded}
        # → agent server halts processing, emits jido.agent.stopping
      end

      test "user cancellation mid-loop" do
        # Signal react.cancel routed to ReAct.Cancelled action
        # → sets step = :cancelled, emits react.done with cancelled: true
        # → subsequent tool.result signals see step != :running and no-op
      end

  ## What this exercise confirms

  - The plugin + middleware surface is sufficient for a non-trivial LLM
    control loop without reintroducing Strategy.
  - Self-dispatch via `Emit{dispatch: nil}` is load-bearing and must stay.
  - The task-spawning directive with timeout covers per-step deadlines
    cleanly; no separate scheduling primitive is needed.
  - Cumulative/idle timeouts and cancellation compose as middleware.
  - Each primitive appears in one layer: state in the slice, control in
    signal routes, side-effects in directives, policy in middleware.
  """
  use ExUnit.Case, async: true

  @moduletag :pending_adr_0011
  @moduletag :skip
end
