defmodule JidoTest.Agent.SignalHandlingTest do
  @moduledoc """
  Tests signal routing through AgentServer.

  Signal handling architecture:
  1. Signals arrive at AgentServer
  2. AgentServer routes signals to actions via strategy.signal_routes or default mapping
  3. Actions are executed via Agent.cmd/2
  4. on_before_cmd/2 can intercept actions for pre-processing
  """
  use JidoTest.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Signal
  alias JidoTest.TestActions

  defmodule EmitTestAction do
    @moduledoc false
    use Jido.Action, name: "emit_test", schema: []

    def run(_signal, _slice, _opts, _ctx) do
      signal = Signal.new!("test.emitted", %{from: "agent"}, source: "/test")
      {:ok, %{}, [%Directive.Emit{signal: signal}]}
    end
  end

  # Agent with actions for signal routing
  defmodule ActionBasedAgent do
    @moduledoc false
    use Jido.Agent,
      name: "action_based_agent",
      path: :domain,
      schema: [
        counter: [type: :integer, default: 0],
        messages: [type: {:list, :any}, default: []]
      ]

    def signal_routes(_ctx) do
      [
        {"increment", TestActions.IncrementAction},
        {"decrement", TestActions.DecrementAction},
        {"record", TestActions.RecordAction},
        {"emit_test", EmitTestAction}
      ]
    end
  end

  # Agent with on_before_cmd hook for pre-processing
  defmodule PreProcessingAgent do
    @moduledoc false
    use Jido.Agent,
      name: "pre_processing_agent",
      path: :domain,
      schema: [
        counter: [type: :integer, default: 0],
        last_action_type: [type: :string, default: nil]
      ]

    def signal_routes(_ctx) do
      [
        {"increment", TestActions.IncrementAction},
        {"decrement", TestActions.DecrementAction}
      ]
    end

    # Intercept actions to capture the action type before processing
    # Handles action module tuples from signal routing
    def on_before_cmd(agent, {action_mod, _params} = action) when is_atom(action_mod) do
      action_name = action_mod.__action_metadata__().name
      agent = %{agent | state: put_in(agent.state, [:domain, :last_action_type], action_name)}
      {:ok, agent, action}
    end

    def on_before_cmd(agent, action), do: {:ok, agent, action}
  end

  describe "signal routing via AgentServer" do
    test "signals are routed to actions by type", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: ActionBasedAgent, id: "signal-route-test", jido: jido)

      # Signal type becomes the action: {"increment", signal.data}
      signal = Signal.new!("increment", %{amount: 5}, source: "/test")
      {:ok, agent} = Jido.AgentServer.call(pid, signal)

      # The IncrementAction should have been called
      assert agent.state.domain.counter == 5

      GenServer.stop(pid)
    end

    test "multiple signals processed in sequence", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: ActionBasedAgent, id: "multi-signal-test", jido: jido)

      signals = [
        Signal.new!("increment", %{amount: 1}, source: "/test"),
        Signal.new!("increment", %{amount: 2}, source: "/test"),
        Signal.new!("increment", %{amount: 3}, source: "/test")
      ]

      final_agent =
        Enum.reduce(signals, nil, fn signal, _acc ->
          {:ok, agent} = Jido.AgentServer.call(pid, signal)
          agent
        end)

      assert final_agent.state.domain.counter == 6

      GenServer.stop(pid)
    end

    test "signal data is passed to action", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: ActionBasedAgent, id: "signal-data-test", jido: jido)

      signal = Signal.new!("record", %{message: "hello"}, source: "/test")
      {:ok, agent} = Jido.AgentServer.call(pid, signal)

      # Fixtures.RecordAction stores the :message value when present
      assert agent.state.domain.messages == ["hello"]

      GenServer.stop(pid)
    end

    test "action can return directives", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: ActionBasedAgent, id: "directive-test", jido: jido)

      signal = Signal.new!("emit_test", %{}, source: "/test")
      {:ok, _agent} = Jido.AgentServer.call(pid, signal)

      # Directive was processed (we can't easily verify Emit was executed,
      # but we verified the action ran without error)
      GenServer.stop(pid)
    end

    test "unknown signal type short-circuits with {:error, _} but does not crash", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(
          agent_module: ActionBasedAgent,
          id: "unknown-signal-test",
          jido: jido
        )

      signal = Signal.new!("unknown_action", %{}, source: "/test")
      # Per ADR 0018, the chain returns {:error, %RoutingError{}}; AgentServer.call/2
      # still replies {:ok, agent} (cast_and_await is the error-aware variant).
      assert {:ok, _agent} = Jido.AgentServer.call(pid, signal)

      # The agent should still be functional despite the error
      signal2 = Signal.new!("increment", %{amount: 1}, source: "/test")
      {:ok, agent} = Jido.AgentServer.call(pid, signal2)
      assert agent.state.domain.counter == 1

      GenServer.stop(pid)
    end
  end

  describe "direct cmd/2 usage" do
    test "cmd/2 works directly with action module tuples" do
      agent = ActionBasedAgent.new()

      {:ok, updated, _directives} =
        ActionBasedAgent.cmd(agent, {TestActions.IncrementAction, %{amount: 5}})

      assert updated.state.domain.counter == 5
    end
  end
end
