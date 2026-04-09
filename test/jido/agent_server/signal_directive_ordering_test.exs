defmodule JidoTest.AgentServer.SignalDirectiveOrderingTest do
  @moduledoc """
  Tests that demonstrate the ordering between signal processing (Agent.cmd)
  and directive execution (drain loop).

  When two async signals are sent, the second signal's cmd can run before
  the first signal's directives are drained, because the cast message is
  already in the GenServer mailbox ahead of the :drain message.
  """
  use JidoTest.Case, async: true

  # ── Test Actions ──────────────────────────────────────────────────────

  defmodule Step1Action do
    @moduledoc false
    use Jido.Action, name: "step1"

    def run(_params, context) do
      IO.inspect(context.state, label: "[Step1Action] state at start of run/2")

      IO.puts(
        "[Step1Action] setting step1_cmd_ran=true, returning directive to set step1_directive_ran=true"
      )

      {:ok, %{step1_cmd_ran: true},
       %JidoTest.SetStateDirective{key: :step1_directive_ran, value: true}}
    end
  end

  defmodule Step2Action do
    @moduledoc false
    use Jido.Action, name: "step2"

    def run(_params, context) do
      saw_cmd = Map.get(context.state, :step1_cmd_ran, false)
      saw_directive = Map.get(context.state, :step1_directive_ran, false)

      IO.inspect(context.state, label: "[Step2Action] state at start of run/2")
      IO.puts("[Step2Action] saw step1_cmd_ran=#{saw_cmd}, step1_directive_ran=#{saw_directive}")

      {:ok, %{step2_saw_cmd_ran: saw_cmd, step2_saw_directive_ran: saw_directive}}
    end
  end

  # ── Test Agent ────────────────────────────────────────────────────────

  defmodule OrderingAgent do
    @moduledoc false
    use Jido.Agent,
      name: "ordering_agent",
      schema: [
        step1_cmd_ran: [type: :boolean, default: false],
        step1_directive_ran: [type: :boolean, default: false],
        step2_saw_cmd_ran: [type: :boolean, default: false],
        step2_saw_directive_ran: [type: :boolean, default: false]
      ]

    def signal_routes(_ctx) do
      [
        {"step1", Step1Action},
        {"step2", Step2Action}
      ]
    end
  end

  # ── Tests ─────────────────────────────────────────────────────────────

  describe "signal vs directive ordering" do
    test "second async signal's cmd runs before first signal's directives drain", %{jido: jido} do
      pid = start_server(%{jido: jido}, OrderingAgent)

      signal1 = signal("step1", %{})
      signal2 = signal("step2", %{})

      # Both casts are sent sequentially from this process, so signal2's cast
      # is already in the mailbox when handle_cast(signal1) runs. When signal1's
      # handler does send(self(), :drain), :drain lands AFTER signal2's cast:
      #
      #   1. handle_cast(signal1) → cmd sets step1_cmd_ran=true
      #      → enqueues SetStateDirective(step1_directive_ran=true)
      #      → send(self(), :drain)
      #      Mailbox: [signal2_cast, :drain]
      #
      #   2. handle_cast(signal2) → cmd reads state:
      #      step1_cmd_ran=true (set by cmd), step1_directive_ran=false (directive hasn't drained!)
      #
      #   3. :drain → executes SetStateDirective → sets step1_directive_ran=true
      Jido.AgentServer.cast(pid, signal1)
      Jido.AgentServer.cast(pid, signal2)

      # Wait for the directive to drain
      eventually_state(pid, fn state ->
        state.agent.state.step1_directive_ran == true
      end)

      {:ok, state} = Jido.AgentServer.state(pid)
      agent_state = state.agent.state

      # Everything ran in the end
      assert agent_state.step1_cmd_ran == true
      assert agent_state.step1_directive_ran == true

      # The proof: Step2 saw the cmd effect but NOT the directive effect
      assert agent_state.step2_saw_cmd_ran == true
      assert agent_state.step2_saw_directive_ran == false
    end
  end
end
