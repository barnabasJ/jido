defmodule Jido.Dsl.AgentTest do
  use ExUnit.Case, async: true

  alias Jido.Agent
  alias Jido.Dsl.Agent.Info, as: AgentInfo

  defmodule SimpleAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "simple_agent"
      description "Bare agent — no plugins, no slices."
      category "test"
      tags ["simple", "test"]
      vsn "1.0.0"
      path :domain

      schema counter: [type: :integer, default: 0],
             status: [type: :atom, default: :idle]
    end
  end

  describe "basic accessors (sectioned `agent do … end`)" do
    test "name/1" do
      assert AgentInfo.name(SimpleAgent) == "simple_agent"
    end

    test "description/1" do
      assert AgentInfo.description(SimpleAgent) == "Bare agent — no plugins, no slices."
    end

    test "category/1" do
      assert AgentInfo.category(SimpleAgent) == "test"
    end

    test "tags/1" do
      assert AgentInfo.tags(SimpleAgent) == ["simple", "test"]
    end

    test "vsn/1" do
      assert AgentInfo.vsn(SimpleAgent) == "1.0.0"
    end

    test "path/1" do
      assert AgentInfo.path(SimpleAgent) == :domain
    end

    test "plugins/1 / slices/1 / middleware/1 default to empty / framework defaults" do
      assert AgentInfo.plugins(SimpleAgent) == []
      # Framework default slices are auto-attached.
      assert Jido.Slices.Memory in AgentInfo.slices(SimpleAgent)
      assert Jido.Identity.Slice in AgentInfo.slices(SimpleAgent)
      assert Jido.Thread.Slice in AgentInfo.slices(SimpleAgent)
      assert AgentInfo.middleware(SimpleAgent) == []
    end

    test "actions/1 returns the union from all attached slices" do
      assert is_list(AgentInfo.actions(SimpleAgent))
    end
  end

  describe "new/1 + cmd/2 + set/2" do
    test "new/1 seeds the agent slice with schema defaults" do
      agent = SimpleAgent.new()
      assert %Agent{} = agent
      assert agent.agent_module == SimpleAgent
      assert agent.name == "simple_agent"
      # Schema defaults applied under the agent's path
      assert get_in(agent.state, [:domain, :counter]) == 0
      assert get_in(agent.state, [:domain, :status]) == :idle
    end

    test "new/1 accepts user-supplied state and merges over defaults" do
      agent = SimpleAgent.new(state: %{counter: 5})
      assert get_in(agent.state, [:domain, :counter]) == 5
    end

    test "set/2 wraps flat attrs into the path slice" do
      agent = SimpleAgent.new()
      {:ok, agent} = SimpleAgent.set(agent, %{status: :running})
      assert get_in(agent.state, [:domain, :status]) == :running
    end
  end

  describe "signal_routes do … end section" do
    defmodule RouteAgent do
      @moduledoc false
      use Jido.Agent

      agent do
        name "route_agent"
      end

      signal_routes do
        route "user.created", JidoTest.PluginTestAction
        route "high.priority", JidoTest.PluginTestAction, priority: 10
      end
    end

    test "section entries become legacy route_spec tuples" do
      routes = AgentInfo.signal_routes(RouteAgent)
      assert {"user.created", JidoTest.PluginTestAction} in routes
      assert {"high.priority", JidoTest.PluginTestAction, 10} in routes
    end
  end

  describe "compile-time errors" do
    test "missing required `name` raises" do
      assert_raise Spark.Error.DslError, fn ->
        defmodule MissingName do
          use Jido.Agent

          agent do
          end
        end
      end
    end

    test "schema without path warns at compile time" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule SchemaNoPath do
            use Jido.Agent

            agent do
              name "schema_no_path"
              schema counter: [type: :integer, default: 0]
            end
          end
        end)

      assert stderr =~ ~r/`schema:` is set.*but `path:` is not/
    end

    test "path without schema warns at compile time" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule PathNoSchema do
            use Jido.Agent

            agent do
              name "path_no_schema"
              path :domain
            end
          end
        end)

      assert stderr =~ ~r/`path: :domain` is set.*but `schema:` is not/
    end
  end
end
