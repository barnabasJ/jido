defmodule JidoTest.AgentWait do
  @moduledoc """
  Subscribe-based wait helpers for agent state changes.

  Per ADR 0021, tests must not poll agent state. Use these helpers for
  any wait whose stop condition is a predicate over the agent's state;
  the legacy state-polling helper has been removed.

  Each helper:

  1. **Fast-paths a `state/3` query** — if the predicate already holds,
     return immediately.
  2. **Registers a `subscribe/4`** to a signal pattern (default `"*"`,
     i.e. fire on every signal) with `once: true` and a selector that
     returns `{:ok, value}` when the predicate matches and `:skip`
     otherwise.
  3. **Re-checks via `state/3`** after the subscription is registered to
     close the registration race (some signal could land between the
     first check and `subscribe/4`).
  4. **Blocks on `assert_receive`-style** receipt of the subscription
     fire message, raising on timeout.

  Selectors run in the agent process after the outermost middleware
  unwinds, so the predicate sees fully post-pipeline state per
  ADR 0016 §2.
  """

  alias Jido.AgentServer

  @default_timeout 500
  # `"**"` is the multi-segment wildcard — matches every signal type.
  # Single `"*"` only matches one segment, so it would miss multi-segment
  # types like `"cron.tick"` or `"jido.agent.lifecycle.ready"`.
  @default_pattern "**"

  @doc """
  Wait for `value_fn.(state)` to return a non-`nil` value. Returns the
  value.

  ## Options

    * `:timeout` - ms to wait (default: #{@default_timeout})
    * `:pattern` - signal pattern to subscribe on (default: `"**"` — the
      multi-segment wildcard, matches every signal type). Use a tighter
      pattern (e.g. `"jido.agent.child.started"`) when you know exactly
      which signal advances the predicate; tighter patterns avoid a
      selector run on every unrelated signal.

  ## Examples

      # Wait until counter reaches 5
      counter =
        JidoTest.AgentWait.await_state_value(pid, fn s ->
          if s.agent.state.domain.counter >= 5, do: s.agent.state.domain.counter
        end)
      assert counter == 5

      # Wait until a child appears, narrow pattern
      child_pid =
        JidoTest.AgentWait.await_state_value(
          pid,
          fn s -> Map.get(s.children, :worker) end,
          pattern: "jido.agent.child.started"
        )
  """
  @spec await_state_value(GenServer.server(), (Jido.AgentServer.State.t() -> any()), keyword()) ::
          any()
  def await_state_value(pid, value_fn, opts \\ []) when is_function(value_fn, 1) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    pattern = Keyword.get(opts, :pattern, @default_pattern)

    state_selector = fn s -> {:ok, value_fn.(s)} end

    subscribe_selector = fn s ->
      case value_fn.(s) do
        nil -> :skip
        value -> {:ok, value}
      end
    end

    case AgentServer.state(pid, state_selector) do
      {:ok, value} when not is_nil(value) ->
        value

      _ ->
        wait_via_subscription(pid, pattern, state_selector, subscribe_selector, timeout)
    end
  end

  defp wait_via_subscription(pid, pattern, state_selector, subscribe_selector, timeout) do
    {:ok, ref} = AgentServer.subscribe(pid, pattern, subscribe_selector, once: true)

    case AgentServer.state(pid, state_selector) do
      {:ok, value} when not is_nil(value) ->
        AgentServer.unsubscribe(pid, ref)
        value

      _ ->
        receive do
          {:jido_subscription, ^ref, %{result: {:ok, value}}} -> value
        after
          timeout ->
            AgentServer.unsubscribe(pid, ref)

            raise ExUnit.AssertionError,
              message:
                "await_state_value/3 predicate not satisfied within #{timeout}ms (pattern=#{inspect(pattern)})"
        end
    end
  end
end
