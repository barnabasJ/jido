defmodule JidoTest.AgentServer.SignalDirectiveOrderingTest do
  @moduledoc """
  Tests the ordering guarantee between signal processing (Agent.cmd/2)
  and directive execution under inline signal processing (ADR 0009).

  Per ADR 0019 / task 0015, directives mutate no state; the cascade-driven
  state changes happen on whatever turn observes the resulting signal.
  Signal A emits an `Emit` directive whose dispatched signal routes via
  `signal_routes` to a state-mutating action; signal A also returns a
  cmd-level slice change. Signal B is cast immediately after.

  When two async signals are cast, signal A runs fully — cmd/2 *and*
  any inline directive I/O — before signal B is picked up from the
  mailbox. So signal B's cmd/2 always sees signal A's slice
  return; the dispatched signal arrives later in the mailbox and is
  processed in its own turn.
  """
  use JidoTest.Case, async: true

  defmodule Step1Action do
    @moduledoc false
    use Jido.Action, name: "step1"

    alias Jido.Agent.Directive
    alias Jido.Signal

    def run(_signal, slice, _opts, _ctx) do
      slice = slice || %{}

      # Signal A's slice update is committed atomically before signal B
      # runs. The Emit directive then casts a `step1.followup` signal —
      # processed in a later mailbox turn by SetFollowupKeyAction.
      followup = Signal.new!(%{type: "step1.followup", source: "/test", data: %{}})

      {:ok, Map.put(slice, :step1_cmd_ran, true), [Directive.emit(followup)]}
    end
  end

  defmodule SetFollowupKeyAction do
    @moduledoc false
    use Jido.Action, name: "set_followup_key"

    def run(_signal, slice, _opts, _ctx) do
      slice = slice || %{}
      {:ok, Map.put(slice, :step1_followup_ran, true), []}
    end
  end

  defmodule Step2Action do
    @moduledoc false
    use Jido.Action, name: "step2"

    def run(_signal, slice, _opts, _ctx) do
      slice = slice || %{}
      saw_cmd = Map.get(slice, :step1_cmd_ran, false)

      {:ok, Map.put(slice, :step2_saw_cmd_ran, saw_cmd), []}
    end
  end

  defmodule OrderingAgent do
    @moduledoc false
    use Jido.Agent,
      name: "ordering_agent",
      path: :domain,
      schema: [
        step1_cmd_ran: [type: :boolean, default: false],
        step1_followup_ran: [type: :boolean, default: false],
        step2_saw_cmd_ran: [type: :boolean, default: false]
      ]

    def signal_routes(_ctx) do
      [
        {"step1", Step1Action},
        {"step1.followup", SetFollowupKeyAction},
        {"step2", Step2Action}
      ]
    end
  end

  describe "inline signal processing ordering" do
    test "signal B sees signal A's cmd-level slice update", %{jido: jido} do
      pid = start_server(%{jido: jido}, OrderingAgent)

      Jido.AgentServer.cast(pid, signal("step1", %{}))
      Jido.AgentServer.cast(pid, signal("step2", %{}))

      agent_state =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.step2_saw_cmd_ran, do: s.agent.state.domain
        end)

      assert agent_state.step1_cmd_ran == true
      assert agent_state.step2_saw_cmd_ran == true
    end

    test "the emitted follow-up signal eventually runs and updates state", %{jido: jido} do
      pid = start_server(%{jido: jido}, OrderingAgent)

      Jido.AgentServer.cast(pid, signal("step1", %{}))

      # The Emit directive on step1 dispatched a `step1.followup` signal
      # back through the same agent; SetFollowupKeyAction sets the key.
      assert true =
               JidoTest.AgentWait.await_state_value(
                 pid,
                 fn s -> s.agent.state.domain.step1_followup_ran || nil end,
                 pattern: "step1.followup"
               )
    end
  end
end
