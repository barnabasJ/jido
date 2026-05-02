defmodule JidoTest.AgentTest do
  use ExUnit.Case, async: true

  alias Jido.Agent
  alias Jido.Dsl.Agent.Info, as: AgentInfo
  alias JidoTest.TestActions
  alias JidoTest.TestAgents

  defmodule ConfiguredRoutesAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "configured_routes_agent"
    end

    signal_routes do
      route "configured.route", JidoTest.TestActions.NoSchema
    end
  end

  defmodule ExtendingRoutesAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "extending_routes_agent"
    end

    signal_routes do
      route "base.route", JidoTest.TestActions.NoSchema
      route "extended.route", JidoTest.TestActions.BasicAction
    end
  end

  describe "module definition" do
    test "defines metadata accessors via Info" do
      assert AgentInfo.name(TestAgents.Basic) == "basic_agent"
      assert AgentInfo.description(TestAgents.Basic) == "A basic test agent"
      assert AgentInfo.category(TestAgents.Basic) == "test"
      assert AgentInfo.tags(TestAgents.Basic) == ["test", "basic"]
      assert AgentInfo.vsn(TestAgents.Basic) == "1.0.0"
    end

    test "minimal agent has default values" do
      assert AgentInfo.name(TestAgents.Minimal) == "minimal_agent"
      assert AgentInfo.description(TestAgents.Minimal) == nil
      # The merged schema is non-empty because default slices contribute schemas.
      assert is_struct(AgentInfo.schema(TestAgents.Minimal))
    end
  end

  describe "signal routes configuration" do
    test "agent's signal_routes section is exposed via Agent.Info.signal_routes/1" do
      routes = AgentInfo.signal_routes(ConfiguredRoutesAgent)
      assert routes == [{"configured.route", JidoTest.TestActions.NoSchema}]
    end

    test "Agent.Info.signal_routes/1 returns configured routes for agents with multiple routes" do
      routes = AgentInfo.signal_routes(ExtendingRoutesAgent)
      assert {"base.route", JidoTest.TestActions.NoSchema} in routes
      assert {"extended.route", JidoTest.TestActions.BasicAction} in routes
      assert length(routes) == 2
    end
  end

  describe "new/1" do
    test "creates agent with auto-generated id" do
      agent = TestAgents.Minimal.new()
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "creates agent with custom id" do
      agent = TestAgents.Minimal.new(id: "custom-123")
      assert agent.id == "custom-123"
    end

    test "generates unique ids for each instance" do
      agent1 = TestAgents.Minimal.new()
      agent2 = TestAgents.Minimal.new()
      assert agent1.id != agent2.id
    end

    test "generates id when nil is passed" do
      agent = TestAgents.Minimal.new(id: nil)
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "generates id when empty string is passed" do
      agent = TestAgents.Minimal.new(id: "")
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "creates agent with initial state" do
      agent = TestAgents.Basic.new(state: %{counter: 10})
      assert agent.state.domain.counter == 10
      assert agent.state.domain.status == :idle
    end

    test "applies schema defaults to state" do
      agent = TestAgents.Basic.new()
      assert agent.state.domain.counter == 0
      assert agent.state.domain.status == :idle
    end

    test "merges initial state with defaults" do
      agent = TestAgents.Basic.new(state: %{counter: 5})
      assert agent.state.domain.counter == 5
      assert agent.state.domain.status == :idle
    end

    test "populates agent metadata" do
      agent = TestAgents.Basic.new()
      assert agent.name == "basic_agent"
      assert agent.description == "A basic test agent"
      assert agent.category == "test"
      assert agent.tags == ["test", "basic"]
      assert agent.vsn == "1.0.0"
    end
  end

  describe "set/2" do
    test "updates state with map" do
      agent = TestAgents.Basic.new()
      {:ok, updated} = TestAgents.Basic.set(agent, %{counter: 42})
      assert updated.state.domain.counter == 42
    end

    test "updates state with keyword list" do
      agent = TestAgents.Basic.new()
      {:ok, updated} = TestAgents.Basic.set(agent, counter: 42, status: :running)
      assert updated.state.domain.counter == 42
      assert updated.state.domain.status == :running
    end

    test "deep merges nested maps" do
      agent = TestAgents.Basic.new(state: %{config: %{a: 1, b: 2}})
      {:ok, updated} = TestAgents.Basic.set(agent, %{config: %{b: 3, c: 4}})
      assert updated.state.domain.config == %{a: 1, b: 3, c: 4}
    end
  end

  describe "validate/2" do
    test "validates state against schema" do
      agent = TestAgents.Basic.new()
      {:ok, validated} = TestAgents.Basic.validate(agent)
      assert validated.state.domain.counter == 0
      assert validated.state.domain.status == :idle
    end

    test "preserves extra fields in non-strict mode" do
      agent = TestAgents.Basic.new(state: %{counter: 0, extra_field: "hello"})
      {:ok, validated} = TestAgents.Basic.validate(agent)
      assert validated.state.domain.extra_field == "hello"
    end

    test "strict mode only keeps schema fields" do
      agent = TestAgents.Basic.new(state: %{counter: 0, status: :idle, extra_field: "hello"})
      {:ok, validated} = TestAgents.Basic.validate(agent, strict: true)
      refute Map.has_key?(Map.get(validated.state, :domain, %{}), :extra_field)
      refute Map.has_key?(validated.state, :extra_field)
    end
  end

  describe "cmd/2" do
    test "executes action module" do
      agent = TestAgents.Basic.new()
      {:ok, updated, _directives} = TestAgents.Basic.cmd(agent, TestActions.NoSchema)
      assert updated.state.domain.result == "No params"
    end

    test "executes action tuple" do
      agent = TestAgents.Basic.new()

      {:ok, updated, _directives} =
        TestAgents.Basic.cmd(agent, {TestActions.BasicAction, %{value: 42}})

      assert updated.state.domain.value == 42
    end

    test "all-or-nothing batch: every action succeeds; slice reflects the last instruction" do
      agent = TestAgents.Basic.new()

      {:ok, updated, directives} =
        TestAgents.Basic.cmd(agent, [
          {TestActions.Add, %{value: 5, amount: 3}},
          {TestActions.Add, %{value: 1, amount: 1}}
        ])

      # Each action returns the full slice; the second overwrites the first.
      assert updated.state.domain.value == 2
      assert directives == []
    end

    test "all-or-nothing batch: middle instruction errors halts the batch and returns the input agent unchanged" do
      agent = TestAgents.Basic.new(state: %{counter: 0})

      assert {:error, %Jido.Error.ExecutionError{}} =
               TestAgents.Basic.cmd(agent, [
                 {TestActions.Add, %{value: 5, amount: 3}},
                 {TestActions.FailingAction, %{reason: "halted"}},
                 {TestActions.Add, %{value: 1, amount: 1}}
               ])
    end

    test "handles %Instruction{} struct directly" do
      agent = TestAgents.Basic.new()

      {:ok, instruction} =
        Jido.Instruction.new(%{action: TestActions.BasicAction, params: %{value: 99}})

      {:ok, updated, _directives} = TestAgents.Basic.cmd(agent, instruction)
      assert updated.state.domain.value == 99
    end

    test "single-instruction error returns {:error, %Jido.Error{}}" do
      agent = TestAgents.Basic.new()

      assert {:error, %Jido.Error.ExecutionError{}} =
               TestAgents.Basic.cmd(agent, {TestActions.BasicAction, %{}})
    end

    test "invalid input format returns {:error, %ValidationError{}}" do
      agent = TestAgents.Basic.new()

      assert {:error, %Jido.Error.ValidationError{message: "Invalid action"}} =
               TestAgents.Basic.cmd(agent, {:unknown, "whatever"})
    end
  end

  describe "cmd/3 with opts" do
    test "passes timeout option to instruction" do
      agent = TestAgents.Basic.new()

      assert {:error, %Jido.Error.ExecutionError{}} =
               TestAgents.Basic.cmd(
                 agent,
                 {TestActions.SlowAction, %{delay_ms: 200}},
                 timeout: 10
               )
    end

    test "passes max_retries option to disable retries" do
      agent = TestAgents.Basic.new()

      start_no_retry = System.monotonic_time(:millisecond)

      assert {:error, %Jido.Error.ExecutionError{}} =
               TestAgents.Basic.cmd(
                 agent,
                 {TestActions.SlowAction, %{delay_ms: 200}},
                 timeout: 10,
                 max_retries: 0
               )

      elapsed_no_retry = System.monotonic_time(:millisecond) - start_no_retry

      start_default = System.monotonic_time(:millisecond)

      assert {:error, %Jido.Error.ExecutionError{}} =
               TestAgents.Basic.cmd(
                 agent,
                 {TestActions.SlowAction, %{delay_ms: 200}},
                 timeout: 10
               )

      elapsed_default = System.monotonic_time(:millisecond) - start_default

      assert elapsed_no_retry < elapsed_default
    end

    test "cmd/2 delegates to cmd/3 with empty opts" do
      agent = TestAgents.Basic.new()

      {:ok, updated1, directives1} = TestAgents.Basic.cmd(agent, TestActions.NoSchema)
      {:ok, updated2, directives2} = TestAgents.Basic.cmd(agent, TestActions.NoSchema, [])

      assert updated1.state == updated2.state
      assert directives1 == directives2
    end

    test "opts are merged into all instructions; first failure halts" do
      agent = TestAgents.Basic.new()

      assert {:error, %Jido.Error.ExecutionError{}} =
               TestAgents.Basic.cmd(
                 agent,
                 [
                   {TestActions.SlowAction, %{delay_ms: 200}},
                   {TestActions.SlowAction, %{delay_ms: 200}}
                 ],
                 timeout: 10,
                 max_retries: 0
               )
    end
  end

  describe "base module functions" do
    test "Agent.new/1 creates agent from attrs (map)" do
      {:ok, agent} = Agent.new(%{name: "test_agent", id: "test-123"})
      assert agent.id == "test-123"
      assert agent.name == "test_agent"
    end

    test "Agent.new/1 creates agent from attrs (keyword list)" do
      {:ok, agent} = Agent.new(name: "test_agent", id: "kw-123")
      assert agent.id == "kw-123"
      assert agent.name == "test_agent"
    end

    test "Agent.new/1 auto-generates id when not provided" do
      {:ok, agent} = Agent.new(%{name: "test_agent"})
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "Agent.new/1 generates id when nil is passed" do
      {:ok, agent} = Agent.new(%{id: nil, name: "test_agent"})
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "Agent.new/1 generates id when empty string is passed" do
      {:ok, agent} = Agent.new(%{id: "", name: "test_agent"})
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "Agent.set/2 updates state" do
      {:ok, agent} = Agent.new(%{id: "test"})
      {:ok, updated} = Agent.set(agent, %{key: "value"})
      assert updated.state.key == "value"
    end

    test "Agent.new/1 returns error for invalid id type" do
      {:error, error} = Agent.new(%{id: 12_345})
      assert error.message == "Agent validation failed"
    end

    test "Agent.validate/2 validates state against schema" do
      {:ok, agent} = Agent.new(%{id: "test", schema: [count: [type: :integer, default: 0]]})
      {:ok, validated} = Agent.validate(agent)
      assert validated.state.count == 0
    end

    test "Agent.validate/2 returns error for invalid state" do
      {:ok, agent} = Agent.new(%{id: "test", schema: [count: [type: :integer, required: true]]})
      agent = %{agent | state: %{count: "not_an_integer"}}
      {:error, error} = Agent.validate(agent)
      assert error.message == "State validation failed"
    end

    test "Agent.schema/0 returns the Zoi schema" do
      schema = Agent.schema()
      assert schema
    end
  end

  describe "actions returning effects" do
    test "action can emit signal via directive" do
      agent = TestAgents.Basic.new()
      {:ok, updated, directives} = TestAgents.Basic.cmd(agent, TestActions.EmitAction)

      assert updated.state.domain.emitted == true
      assert [%Jido.Directives.Emit{signal: signal}] = directives
      assert signal.type == "test.emitted"
    end

    test "action can return multiple directives" do
      agent = TestAgents.Basic.new()
      {:ok, updated, directives} = TestAgents.Basic.cmd(agent, TestActions.MultiEffectAction)

      assert updated.state.domain.triggered == true
      assert length(directives) == 2
      assert [%Jido.Directives.Emit{}, %Jido.Directives.Schedule{}] = directives
    end

    test "SliceUpdate writes multiple slices in one action turn" do
      agent =
        TestAgents.Basic.new(state: %{domain: %{prior: true}, audit: %{last_event: :none}})

      {:ok, updated, directives} = TestAgents.Basic.cmd(agent, TestActions.MultiSliceAction)

      assert updated.state.domain == %{primary: "result"}
      assert updated.state.audit == %{last_event: :touched}
      assert directives == []
    end
  end

  describe "Zoi schema support" do
    test "agent works with Zoi schema" do
      agent = TestAgents.ZoiSchema.new()
      assert agent.name == "zoi_schema_agent"
    end

    test "validate works with Zoi schema" do
      agent = TestAgents.ZoiSchema.new(state: %{status: :running, count: 5})
      {:ok, validated} = TestAgents.ZoiSchema.validate(agent)
      assert validated.state.domain.status == :running
      assert validated.state.domain.count == 5
    end
  end

  describe "plugin routes" do
    test "plugin_routes/0 returns expanded routes with prefix" do
      routes = AgentInfo.plugin_routes(TestAgents.AgentWithPluginRoutes)

      assert length(routes) == 2
      assert {"test_routes_plugin.post", JidoTest.PluginTestAction, -10} in routes
      assert {"test_routes_plugin.list", JidoTest.PluginTestAction, -10} in routes
    end

    test "compile-time conflict detection emits a warning for duplicate routes" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule ConflictAgent do
            use Jido.Agent,
              middleware: [TestAgents.TestPluginWithRoutes]

            agent do
              name "conflict_agent"
            end

            slices do
              slice(:test_routes, TestAgents.TestPluginWithRoutes)
              slice(:test_routes, TestAgents.TestPluginWithRoutes)
            end
          end
        end)

      assert stderr =~ ~r/Route conflict|Duplicate.*paths|same path/
    end
  end
end
