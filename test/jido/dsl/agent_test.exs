defmodule Jido.Dsl.AgentTest do
  use ExUnit.Case, async: true

  alias Jido.Agent

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

    def signal_routes(_ctx), do: []
  end

  describe "basic accessors (sectioned `agent do … end`)" do
    test "name/0" do
      assert SimpleAgent.name() == "simple_agent"
    end

    test "description/0" do
      assert SimpleAgent.description() == "Bare agent — no plugins, no slices."
    end

    test "category/0" do
      assert SimpleAgent.category() == "test"
    end

    test "tags/0" do
      assert SimpleAgent.tags() == ["simple", "test"]
    end

    test "vsn/0" do
      assert SimpleAgent.vsn() == "1.0.0"
    end

    test "path/0" do
      assert SimpleAgent.path() == :domain
    end

    test "plugins/0 / slices/0 / middleware/0 default to empty / framework defaults" do
      assert SimpleAgent.plugins() == []
      # Framework default slices are auto-attached.
      assert Jido.Memory.Slice in SimpleAgent.slices()
      assert Jido.Identity.Slice in SimpleAgent.slices()
      assert Jido.Thread.Slice in SimpleAgent.slices()
      assert SimpleAgent.middleware() == []
    end

    test "actions/0 returns the union from all attached slices" do
      assert is_list(SimpleAgent.actions())
    end

    test "__agent_metadata__/0 returns the full metadata map" do
      meta = SimpleAgent.__agent_metadata__()
      assert meta.name == "simple_agent"
      assert meta.description == "Bare agent — no plugins, no slices."
      assert meta.category == "test"
      assert meta.tags == ["simple", "test"]
      assert meta.vsn == "1.0.0"
      assert meta.module == SimpleAgent
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
      routes = RouteAgent.signal_routes()
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
