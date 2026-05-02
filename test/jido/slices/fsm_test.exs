defmodule JidoTest.Plugin.FSMTest do
  use ExUnit.Case, async: true

  alias Jido.Slices.FSM
  alias Jido.Slices.FSM.Transition

  defmodule DefaultFSMAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "fsm_default"
    end

    slices do
      slice(:fsm, FSM)
    end
  end

  defmodule ConfiguredFSMAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "fsm_configured"
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

  describe "Plugin.Info surface" do
    alias Jido.Dsl.Plugin.Info, as: PluginInfo

    test "FSM path is :fsm" do
    end

    test "FSM signal_routes routes jido.fsm.transition" do
      assert {"jido.fsm.transition", Transition} in PluginInfo.signal_routes(FSM)
    end

    test "FSM actions return the Transition action" do
      assert Transition in PluginInfo.actions(FSM)
    end
  end

  describe "default FSM (no per-agent config)" do
    test "agent boots with the default initial_state" do
      agent = DefaultFSMAgent.new()
      assert agent.state.fsm.state == "idle"
      assert agent.state.fsm.initial_state == "idle"
      assert agent.state.fsm.history == []
      assert agent.state.fsm.terminal? == false
    end

    test "an allowed transition mutates state" do
      agent = DefaultFSMAgent.new()

      {:ok, agent, _} =
        DefaultFSMAgent.cmd(agent, {Transition, %{to: "processing"}})

      assert agent.state.fsm.state == "processing"
      assert [%{from: "idle", to: "processing"}] = agent.state.fsm.history
    end

    test "transitioning into a terminal state flips terminal?" do
      agent = DefaultFSMAgent.new()
      {:ok, agent, _} = DefaultFSMAgent.cmd(agent, {Transition, %{to: "processing"}})
      {:ok, agent, _} = DefaultFSMAgent.cmd(agent, {Transition, %{to: "completed"}})

      assert agent.state.fsm.state == "completed"
      assert agent.state.fsm.terminal? == true
    end
  end

  describe "configured FSM" do
    test "per-agent config seeds the slice through the schema's transform" do
      agent = ConfiguredFSMAgent.new()
      assert agent.state.fsm.state == "ready"
      assert agent.state.fsm.terminal_states == ["done", "errored"]
      assert agent.state.fsm.terminal? == false
    end

    test "respects the configured transitions map" do
      agent = ConfiguredFSMAgent.new()
      {:ok, agent, _} = ConfiguredFSMAgent.cmd(agent, {Transition, %{to: "working"}})
      assert agent.state.fsm.state == "working"

      {:ok, agent, _} = ConfiguredFSMAgent.cmd(agent, {Transition, %{to: "errored"}})
      assert agent.state.fsm.state == "errored"
      assert agent.state.fsm.terminal? == true
    end

    test "rejects a transition not in the allowed list" do
      agent = ConfiguredFSMAgent.new()

      assert {:error, _reason} =
               ConfiguredFSMAgent.cmd(agent, {Transition, %{to: "unknown"}})
    end
  end
end
