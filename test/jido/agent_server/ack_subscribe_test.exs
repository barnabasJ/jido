defmodule JidoTest.AgentServer.AckSubscribeTest do
  use JidoTest.Case, async: false

  alias Jido.AgentServer

  defmodule WriteAction do
    @moduledoc false
    use Jido.Action, name: "write", path: :app, schema: []

    def run(%Jido.Signal{data: %{value: v}}, slice, _opts, _ctx) do
      {:ok, %{slice | value: v, status: :written}, []}
    end
  end

  defmodule FailingAction do
    @moduledoc false
    use Jido.Action, name: "fail", path: :app, schema: []

    def run(_signal, _slice, _opts, _ctx) do
      {:error, :intentional_action_failure}
    end
  end

  defmodule TestAgent do
    @moduledoc false
    use Jido.Agent,
      name: "ack_subscribe_agent",
      path: :app,
      schema: [
        value: [type: :integer, default: 0],
        status: [type: :atom, default: :idle]
      ]

    def signal_routes(_ctx) do
      [
        {"write", JidoTest.AgentServer.AckSubscribeTest.WriteAction},
        {"fail", JidoTest.AgentServer.AckSubscribeTest.FailingAction}
      ]
    end
  end

  defmodule FlakyAction do
    @moduledoc false
    use Jido.Action, name: "flaky", path: :app, schema: []

    @counter_key {__MODULE__, :counter}

    def reset(name) do
      :persistent_term.put({@counter_key, name}, :counters.new(1, []))
    end

    def attempts(name) do
      :counters.get(:persistent_term.get({@counter_key, name}), 1)
    end

    def run(%Jido.Signal{data: %{name: name, succeed_after: succeed_after}}, slice, _, _) do
      counter = :persistent_term.get({@counter_key, name})
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      if n >= succeed_after do
        {:ok, %{slice | value: succeed_after, status: :written}, []}
      else
        {:error, :transient}
      end
    end
  end

  defmodule RetryingAgent do
    @moduledoc false
    use Jido.Agent,
      name: "retrying_agent",
      path: :app,
      schema: [
        value: [type: :integer, default: 0],
        status: [type: :atom, default: :idle]
      ],
      middleware: [
        {Jido.Middleware.Retry, %{max_attempts: 3, pattern: "flaky"}}
      ]

    def signal_routes(_ctx) do
      [{"flaky", JidoTest.AgentServer.AckSubscribeTest.FlakyAction}]
    end
  end

  describe "call/4" do
    test "runs the selector after the signal completes and returns its value", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.call(
          pid,
          signal("write", %{value: 7}),
          fn %AgentServer.State{agent: agent} ->
            case agent.state.app.status do
              :written -> {:ok, agent.state.app.value}
              _ -> {:error, :not_yet}
            end
          end,
          timeout: 5_000
        )

      assert {:ok, 7} = result
    end

    test "returns {:error, reason} when the selector returns an error tuple", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.call(
          pid,
          signal("write", %{value: 1}),
          fn _state -> {:error, :selector_says_no} end,
          timeout: 1_000
        )

      assert {:error, :selector_says_no} = result
    end

    test "delivers {:error, %Jido.Error{}} verbatim when the action errors; selector is skipped",
         %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.call(
          pid,
          signal("fail"),
          fn _state -> {:ok, :selector_should_be_skipped} end,
          timeout: 1_000
        )

      assert {:error, %Jido.Error.ExecutionError{}} = result
    end

    test "subscribers' selectors run even when the chain returned {:error, _}", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      caller = self()

      {:ok, ref} =
        AgentServer.subscribe(
          pid,
          "fail",
          fn _state ->
            send(caller, :subscriber_ran)
            :skip
          end,
          []
        )

      :ok = AgentServer.cast(pid, signal("fail"))

      assert_receive :subscriber_ran, 1_000
      :ok = AgentServer.unsubscribe(pid, ref)
    end

    test "Retry middleware re-invokes next on {:error, _}; selector fires once with the eventual success",
         %{jido: jido} do
      pid = start_server(%{jido: jido}, RetryingAgent)
      :ok = AgentServer.await_ready(pid)

      key = {:flaky, System.unique_integer([:positive])}
      FlakyAction.reset(key)

      # The action succeeds on the 4th invocation. Each middleware attempt
      # calls the action ≥1 time (Exec may also retry), so 3 middleware
      # attempts × ≥1 invocation comfortably exceeds 4.
      result =
        AgentServer.call(
          pid,
          signal("flaky", %{name: key, succeed_after: 4}),
          fn %AgentServer.State{agent: agent} ->
            case agent.state.app.status do
              :written -> {:ok, agent.state.app.value}
              _ -> {:error, :not_yet}
            end
          end,
          timeout: 2_000
        )

      # Eventual success crosses the boundary as a single reply
      # (Retry retries internally; the outermost return fires the selector once).
      assert {:ok, 4} = result
      assert FlakyAction.attempts(key) >= 4
    end

    test "Retry middleware exhausts max_attempts; caller receives the final {:error, _}",
         %{jido: jido} do
      pid = start_server(%{jido: jido}, RetryingAgent)
      :ok = AgentServer.await_ready(pid)

      key = {:flaky, System.unique_integer([:positive])}
      FlakyAction.reset(key)

      result =
        AgentServer.call(
          pid,
          signal("flaky", %{name: key, succeed_after: 9_999}),
          fn _state -> {:ok, :should_be_skipped} end,
          timeout: 2_000
        )

      assert {:error, %Jido.Error.ExecutionError{}} = result
      # Three middleware attempts, each may also Exec-retry, so >= 3.
      assert FlakyAction.attempts(key) >= 3
    end

    test "raising selector surfaces as {:error, {:selector_raised, _, _}}; agent stays alive",
         %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.call(
          pid,
          signal("write", %{value: 9}),
          fn _state -> raise "selector boom" end,
          timeout: 1_000
        )

      assert {:error, {:selector_raised, %RuntimeError{message: "selector boom"}, _stacktrace}} =
               result

      assert Process.alive?(pid)
    end
  end

  describe "subscribe/4" do
    test "delivers a result on the first matching signal when once: true", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, ref} =
        AgentServer.subscribe(
          pid,
          "write",
          fn %AgentServer.State{agent: agent} ->
            {:ok, agent.state.app.value}
          end,
          once: true
        )

      :ok = AgentServer.cast(pid, signal("write", %{value: 42}))

      assert_receive {:jido_subscription, ^ref, %{result: {:ok, 42}}}, 5_000
    end

    test "with :skip return, keeps the subscription alive across multiple signals", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      caller = self()

      {:ok, ref} =
        AgentServer.subscribe(
          pid,
          "write",
          fn %AgentServer.State{agent: agent} ->
            send(caller, {:saw_value, agent.state.app.value})
            :skip
          end,
          []
        )

      :ok = AgentServer.cast(pid, signal("write", %{value: 1}))
      :ok = AgentServer.cast(pid, signal("write", %{value: 2}))

      assert_receive {:saw_value, 1}, 5_000
      assert_receive {:saw_value, 2}, 5_000

      :ok = AgentServer.unsubscribe(pid, ref)
    end

    test "unsubscribe/2 stops the subscription", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, ref} =
        AgentServer.subscribe(pid, "write", fn _s -> {:ok, :received} end, [])

      :ok = AgentServer.unsubscribe(pid, ref)
      :ok = AgentServer.cast(pid, signal("write", %{value: 99}))

      refute_receive {:jido_subscription, ^ref, _}, 200
    end

    test "ignores signals that don't match the pattern", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, ref} =
        AgentServer.subscribe(pid, "specific.path", fn _ -> {:ok, :hit} end, once: true)

      :ok = AgentServer.cast(pid, signal("write", %{value: 1}))

      refute_receive {:jido_subscription, ^ref, _}, 200
      :ok = AgentServer.unsubscribe(pid, ref)
    end
  end
end
