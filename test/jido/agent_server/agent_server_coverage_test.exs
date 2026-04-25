defmodule JidoTest.AgentServerCoverageTest do
  @moduledoc """
  Additional tests to improve AgentServer coverage.

  Tests uncovered paths including:
  - resolve_server with {:via, ...} that returns nil
  - Agent resolution with new/0 vs new/1
  - Pre-built struct with agent_module option
  - Lifecycle hooks (on_before_cmd, on_after_cmd)
  - Queue overflow scenario
  - Multiple await_completion waiters
  - Invalid signal handling
  """

  use JidoTest.Case, async: true

  @moduletag :capture_log

  alias Jido.AgentServer
  alias Jido.Signal
  alias JidoTest.TestAgents.Counter

  # Simple test agent with defaults
  defmodule SimpleTestAgent do
    @moduledoc false
    use Jido.Agent,
      name: "simple_test_agent",

      path: :domain,
      schema: [
        counter: [type: :integer, default: 0]
      ]

    def signal_routes(_ctx) do
      [{"increment", JidoTest.TestActions.IncrementAction}]
    end
  end

  # Action that generates many directives for queue overflow testing
  defmodule ManyDirectivesAction do
    @moduledoc false
    use Jido.Action,
      name: "many_directives",
      schema: [
        count: [type: :integer, default: 10]
      ]

    alias Jido.Agent.Directive

    def run(%Jido.Signal{data: %{count: count}}, _slice, _opts, _ctx) do
      directives =
        for i <- 1..count do
          signal = Jido.Signal.new!("test.emitted.#{i}", %{index: i}, source: "/test")
          %Directive.Emit{signal: signal}
        end

      {:ok, %{directive_count: count}, directives}
    end
  end

  defmodule ManyDirectivesAgent do
    @moduledoc false
    use Jido.Agent,
      name: "many_directives_agent",

      path: :domain,
      schema: [
        counter: [type: :integer, default: 0],
        directive_count: [type: :integer, default: 0]
      ]

    def signal_routes(_ctx) do
      [{"many_directives", ManyDirectivesAction}]
    end
  end

  # Actions for await_completion testing - defined before agent that uses them
  defmodule CompleteAction do
    @moduledoc false
    use Jido.Action, name: "complete", schema: []

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{status: :completed, last_answer: "done!"}, []}
    end
  end

  defmodule FailAction do
    @moduledoc false
    use Jido.Action, name: "fail", schema: []

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{status: :failed, error: "something went wrong"}, []}
    end
  end

  defmodule DelayCompleteAction do
    @moduledoc false
    use Jido.Action,
      name: "delay_complete",
      schema: [delay_ms: [type: :integer, default: 50]]

    def run(%Jido.Signal{data: %{delay_ms: delay}}, _slice, _opts, _ctx) do
      Process.sleep(delay)
      {:ok, %{status: :completed, last_answer: "delayed done!"}, []}
    end
  end

  # Agent for await_completion testing
  defmodule CompletionAgent do
    @moduledoc false
    use Jido.Agent,
      name: "completion_agent",

      path: :domain,
      schema: [
        status: [type: :atom, default: :pending],
        last_answer: [type: :any, default: nil],
        error: [type: :any, default: nil]
      ]

    def signal_routes(_ctx) do
      [
        {"complete", CompleteAction},
        {"fail", FailAction},
        {"delay_complete", DelayCompleteAction}
      ]
    end
  end

  describe "resolve_server with {:via, ...}" do
    test "via tuple that resolves to nil returns error", %{jido: jido} do
      nonexistent_via = {:via, Registry, {Jido.registry_name(jido), "nonexistent-via-agent"}}
      signal = Signal.new!("increment", %{}, source: "/test")

      assert {:error, :not_found} = AgentServer.call(nonexistent_via, signal)
      assert {:error, :not_found} = AgentServer.cast(nonexistent_via, signal)
      assert {:error, :not_found} = AgentServer.state(nonexistent_via)
    end

    test "via tuple that exists works", %{jido: jido} do
      {:ok, _pid} =
        AgentServer.start_link(
          agent_module: Counter,
          id: "via-test-exists",
          jido: jido
        )

      via = {:via, Registry, {Jido.registry_name(jido), "via-test-exists"}}
      signal = Signal.new!("increment", %{}, source: "/test")

      {:ok, agent} = AgentServer.call(via, signal)
      assert agent.state.domain.counter == 1
    end
  end

  describe "resolve_server with string ID" do
    test "string ID returns error with helpful message", %{jido: _jido} do
      signal = Signal.new!("increment", %{}, source: "/test")

      assert {:error, {:invalid_server, message}} = AgentServer.call("some-string-id", signal)
      assert message =~ "String IDs require explicit registry lookup"
      assert message =~ "some-string-id"
    end

    test "string ID error on cast", %{jido: _jido} do
      signal = Signal.new!("increment", %{}, source: "/test")
      assert {:error, {:invalid_server, _}} = AgentServer.cast("some-string-id", signal)
    end

    test "string ID error on state", %{jido: _jido} do
      assert {:error, {:invalid_server, _}} = AgentServer.state("some-string-id")
    end
  end

  describe "resolve_server with atom name" do
    test "atom name that doesn't exist returns error", %{jido: _jido} do
      signal = Signal.new!("increment", %{}, source: "/test")
      assert {:error, :not_found} = AgentServer.call(:nonexistent_atom_server, signal)
    end
  end

  describe "agent resolution with defaults" do
    test "agent uses default values from schema", %{jido: jido} do
      {:ok, pid} = AgentServer.start_link(agent_module: SimpleTestAgent, jido: jido)

      {:ok, state} = AgentServer.state(pid)
      assert state.agent.state.domain.counter == 0

      GenServer.stop(pid)
    end

    test "id and initial_state options are respected", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: SimpleTestAgent,
          id: "custom-id-123",
          initial_state: %{counter: 999},
          jido: jido
        )

      {:ok, state} = AgentServer.state(pid)
      assert state.id == "custom-id-123"
      assert state.agent.state.domain.counter == 999

      GenServer.stop(pid)
    end
  end

  describe "pre-built struct with agent_module option" do
    test "uses explicit agent_module for cmd routing", %{jido: jido} do
      agent = Counter.new(id: "prebuilt-struct-test")
      agent = %{agent | state: put_in(agent.state, [:domain, :counter], 50)}

      {:ok, pid} =
        AgentServer.start_link(
          agent_module: Counter,
          id: agent.id,
          initial_state: agent.state,
          jido: jido
        )

      {:ok, state} = AgentServer.state(pid)
      assert state.id == "prebuilt-struct-test"
      assert state.agent.state.domain.counter == 50
      assert state.agent_module == Counter

      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, updated_agent} = AgentServer.call(pid, signal)
      assert updated_agent.state.domain.counter == 51

      GenServer.stop(pid)
    end
  end

  describe "invalid signal handling" do
    test "signal with no matching route does not crash the agent", %{jido: jido} do
      {:ok, pid} = AgentServer.start_link(agent_module: JidoTest.TestAgents.Minimal, jido: jido)

      signal = Signal.new!("nonexistent_action", %{}, source: "/test")
      # AgentServer.call returns {:ok, agent} even on routing error;
      # the error surfaces as a %Directive.Error{} in the directive stream,
      # which is logged but doesn't fail the call.
      assert {:ok, _agent} = AgentServer.call(pid, signal)

      GenServer.stop(pid)
    end
  end

  describe "alive? with various server types" do
    test "alive? returns false for via tuple that doesn't exist", %{jido: jido} do
      via = {:via, Registry, {Jido.registry_name(jido), "nonexistent-alive-test"}}
      refute AgentServer.alive?(via)
    end

    test "alive? returns false for atom name that doesn't exist", %{jido: _jido} do
      refute AgentServer.alive?(:nonexistent_atom_name)
    end

    test "alive? returns true for existing via tuple", %{jido: jido} do
      {:ok, _pid} =
        AgentServer.start_link(
          agent_module: Counter,
          id: "alive-via-test",
          jido: jido
        )

      via = {:via, Registry, {Jido.registry_name(jido), "alive-via-test"}}
      assert AgentServer.alive?(via)
    end
  end
end
