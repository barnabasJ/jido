defmodule Jido.Plugin.FSMSmokeTest do
  @moduledoc """
  Narrow smoke coverage for the FSM port from strategy → plugin (C3 of
  ADR 0014). The full FSM test suite at
  `test/jido/agent/strategy_fsm_test.exs` is red until C8 rewrites it
  against `Jido.Plugin.FSM`; these tests give the C3 commit a green gate
  so a port bug doesn't masquerade as a test-rewrite bug later.
  """

  use ExUnit.Case, async: true

  alias Jido.Plugin.FSM
  alias Jido.Plugin.FSM.Transition

  defmodule DefaultFSMAgent do
    @moduledoc false
    use Jido.Agent,
      name: "default_fsm_agent",
      path: :app,
      plugins: [FSM]
  end

  defmodule ConfiguredFSMAgent do
    @moduledoc false
    use Jido.Agent,
      name: "configured_fsm_agent",
      path: :app,
      plugins: [
        {FSM,
         %{
           initial_state: "ready",
           transitions: %{
             "ready" => ["working", "done"],
             "working" => ["ready", "done", "errored"],
             "done" => [],
             "errored" => []
           },
           terminal_states: ["done", "errored"]}}
      ]
  end

  describe "agent boot" do
    test "an agent with `plugins: [Jido.Plugin.FSM]` starts with default slice state" do
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
