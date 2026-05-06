defmodule Jido.Slices.FSMSmokeTest do
  @moduledoc """
  Narrow smoke coverage for the FSM slice (originally ported from
  strategy → plugin in C3 of ADR 0014, now a pure slice).
  """

  use ExUnit.Case, async: true

  alias Jido.Slices.FSM
  alias Jido.Slices.FSM.Transition

  defmodule DefaultFSMAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "default_fsm_agent"
    end

    slices do
      slice(:fsm, FSM)
    end
  end

  defmodule ConfiguredFSMAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "configured_fsm_agent"
    end

    slices do
      slice(:fsm, FSM,
        options: [
          initial_state: "ready",
          transitions: %{
            "ready" => ["working", "done"],
            "working" => ["ready", "done", "errored"],
            "done" => [],
            "errored" => []
          },
          terminal_states: ["done", "errored"]
        ]
      )
    end
  end

  describe "agent boot" do
    test "an agent with `plugins: [Jido.Slices.FSM]` starts with default slice state" do
      agent = DefaultFSMAgent.new()

      assert agent.state.fsm.state == "idle"
      assert agent.state.fsm.history == []
      assert agent.state.fsm.terminal? == false
      assert agent.state.fsm.initial_state == "idle"
      assert is_map(agent.state.fsm.transitions)
      assert "completed" in agent.state.fsm.terminal_states
    end

    test "per-agent config seeds the slice via mount/2" do
      agent = ConfiguredFSMAgent.new()

      assert agent.state.fsm.state == "ready"
      assert agent.state.fsm.initial_state == "ready"
      assert agent.state.fsm.terminal_states == ["done", "errored"]
    end
  end

  describe "transition action" do
    test "a routed transition signal mutates `agent.state.fsm.state`" do
      agent = DefaultFSMAgent.new()

      {:ok, agent, _directives} =
        DefaultFSMAgent.cmd(agent, {Transition, %{to: "processing"}})

      assert agent.state.fsm.state == "processing"
      assert length(agent.state.fsm.history) == 1
    end

    test "transitioning into a terminal state flips `terminal?`" do
      agent = DefaultFSMAgent.new()

      {:ok, agent, _} = DefaultFSMAgent.cmd(agent, {Transition, %{to: "processing"}})
      {:ok, agent, _} = DefaultFSMAgent.cmd(agent, {Transition, %{to: "completed"}})

      assert agent.state.fsm.state == "completed"
      assert agent.state.fsm.terminal? == true
    end

    test "history records one entry per successful transition, oldest first" do
      agent = DefaultFSMAgent.new()

      {:ok, agent, _} = DefaultFSMAgent.cmd(agent, {Transition, %{to: "processing"}})
      {:ok, agent, _} = DefaultFSMAgent.cmd(agent, {Transition, %{to: "idle"}})
      {:ok, agent, _} = DefaultFSMAgent.cmd(agent, {Transition, %{to: "processing"}})

      assert [
               %{from: "idle", to: "processing"},
               %{from: "processing", to: "idle"},
               %{from: "idle", to: "processing"}
             ] = agent.state.fsm.history
    end
  end
end
