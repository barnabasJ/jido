defmodule JidoTest.AgentServer.SignalDirectiveOrderingTest do
  @moduledoc """
  Tests the ordering guarantee between signal processing (Agent.cmd/2) and
  directive execution under inline signal processing (ADR 0009).

  When two async signals are cast, signal A runs fully — cmd/2 *and* all of
  its directives — before signal B is picked up from the mailbox. So signal
  B's cmd/2 always sees every synchronous state transition made by signal
  A's directives, never a partial prefix.

  This is a strictly stronger guarantee than the previous drain-loop
  architecture provided.
  """
  use JidoTest.Case, async: true

  # ── Test Actions ──────────────────────────────────────────────────────

  defmodule Step1Action do
    @moduledoc false
    use Jido.Action, name: "step1"

    def run(_signal, slice, _opts, _ctx) do
      # Sets step1_cmd_ran via the cmd state update; the emitted directive
      # then sets step1_directive_ran via a state-op directive.
      slice = slice || %{}

      {:ok, Map.put(slice, :step1_cmd_ran, true),
       [%JidoTest.SetStateDirective{key: :step1_directive_ran, value: true}]}
    end
  end

  defmodule Step2Action do
    @moduledoc false
    use Jido.Action, name: "step2"

    def run(_signal, slice, _opts, _ctx) do
      slice = slice || %{}
      saw_cmd = Map.get(slice, :step1_cmd_ran, false)
      saw_directive = Map.get(slice, :step1_directive_ran, false)

      {:ok,
       Map.merge(slice, %{step2_saw_cmd_ran: saw_cmd, step2_saw_directive_ran: saw_directive}),
       []}
    end
  end

  # ── Test Agent ────────────────────────────────────────────────────────

  defmodule OrderingAgent do
    @moduledoc false
    use Jido.Agent,
      name: "ordering_agent",
      path: :domain,
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

  describe "inline signal processing ordering" do
    test "signal B sees all synchronous state updates from signal A's directives",
         %{jido: jido} do
      pid = start_server(%{jido: jido}, OrderingAgent)

      signal1 = signal("step1", %{})
      signal2 = signal("step2", %{})

      # Two casts: signal1 is handled end-to-end (cmd + all directives) before
      # signal2 is pulled from the mailbox. So step2 sees both step1_cmd_ran
      # AND step1_directive_ran set to true.
      Jido.AgentServer.cast(pid, signal1)
      Jido.AgentServer.cast(pid, signal2)

      eventually_state(pid, fn state ->
        state.agent.state.domain.step2_saw_cmd_ran
      end)

      {:ok, state} = Jido.AgentServer.state(pid)
      agent_state = state.agent.state.domain

      assert agent_state.step1_cmd_ran == true
      assert agent_state.step1_directive_ran == true

      # The atomicity guarantee: step2 observed BOTH the cmd-level update and
      # the directive's synchronous state transition.
      assert agent_state.step2_saw_cmd_ran == true
      assert agent_state.step2_saw_directive_ran == true
    end
  end
end
