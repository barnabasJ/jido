defmodule Jido.Dsl.AgentOptionalPathTest do
  use ExUnit.Case, async: true

  alias Jido.Agent
  alias Jido.Dsl.Agent.Info, as: AgentInfo

  describe "path-less agent compiles" do
    defmodule NoOpAgent do
      @moduledoc false
      use Jido.Agent, default_slices: false

      agent do
        name "noop_agent"
        description "No own slice, no extensions, no default slices."
      end
    end

    test "with no extensions and default_slices disabled" do
      assert AgentInfo.name(NoOpAgent) == "noop_agent"
      assert AgentInfo.path(NoOpAgent) == nil
      assert AgentInfo.slice_instances(NoOpAgent) == []
      assert AgentInfo.slices(NoOpAgent) == []
    end

    test "new/1 produces an agent with empty state and no nil-keyed entry" do
      agent = NoOpAgent.new()
      assert %Agent{} = agent
      assert agent.state == %{}
      refute Map.has_key?(agent.state, nil)
    end

    test "new/1 with user-state preserves keys without wrapping under nil" do
      agent = NoOpAgent.new(state: %{anything: 1})
      refute Map.has_key?(agent.state, nil)
      assert agent.state[:anything] == 1
    end

    test "set/2 does not wrap flat attrs under a nil key" do
      agent = NoOpAgent.new()
      {:ok, agent} = NoOpAgent.set(agent, %{counter: 5})
      refute Map.has_key?(agent.state, nil)
      assert agent.state[:counter] == 5
    end

    defmodule CompositionAgent do
      @moduledoc false
      use Jido.Agent,
        default_slices: %{memory: false, thread: false, identity: false}

      agent do
        name "composition_agent"
        description "Composition over a single contributed slice."
      end

      slices do
        slice(:memory, Jido.Slices.Memory)
      end
    end

    test "with extensions: [Jido.Slices.Memory], slice_instances/1 contains the contributed slice" do
      assert AgentInfo.path(CompositionAgent) == nil
      paths = Enum.map(AgentInfo.slice_instances(CompositionAgent), & &1.path)
      assert :memory in paths
    end

    test "the agent struct's path-related state stays free of a nil-keyed entry" do
      agent = CompositionAgent.new()
      refute Map.has_key?(agent.state, nil)
    end
  end

  describe "PathSchemaPair verifier" do
    test "compiles when both `path` and `schema` are set" do
      defmodule BothSet do
        @moduledoc false
        use Jido.Agent

        agent do
          name "both_set"
          path :domain
          schema counter: [type: :integer, default: 0]
        end
      end

      assert AgentInfo.path(BothSet) == :domain
    end

    test "warns when `schema` is set but `path` is not" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule SchemaOnly do
            use Jido.Agent

            agent do
              name "schema_only"
              schema counter: [type: :integer, default: 0]
            end
          end
        end)

      assert stderr =~ ~r/`schema:` is set.*but `path:` is not/
    end

    test "warns when `path` is set but `schema` is not" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule PathOnly do
            use Jido.Agent

            agent do
              name "path_only"
              path :domain
            end
          end
        end)

      assert stderr =~ ~r/`path: :domain` is set.*but `schema:` is not/
    end

    test "compiles when neither `path` nor `schema` is set" do
      defmodule NeitherSet do
        @moduledoc false
        use Jido.Agent, default_slices: false

        agent do
          name "neither_set"
        end
      end

      assert AgentInfo.path(NeitherSet) == nil
    end
  end

  describe "default-slices interplay with a path-less agent" do
    defmodule PathLessWithDefaults do
      @moduledoc false
      use Jido.Agent

      agent do
        name "path_less_with_defaults"
      end
    end

    test "default slices are still attached" do
      paths = Enum.map(AgentInfo.slice_instances(PathLessWithDefaults), & &1.path)
      assert :memory in paths
      assert :thread in paths
      assert :identity in paths
    end

    test "no nil-keyed state entry after new/1" do
      agent = PathLessWithDefaults.new()
      refute Map.has_key?(agent.state, nil)
    end
  end

  describe "signal_routes / schedules sections work without path" do
    defmodule RoutingPathLess do
      @moduledoc false
      use Jido.Agent, default_slices: false

      agent do
        name "routing_path_less"
      end

      signal_routes do
        route "ping", JidoTest.PluginTestAction
      end
    end

    test "signal_routes/1 returns the host-declared routes" do
      assert {"ping", JidoTest.PluginTestAction} in AgentInfo.signal_routes(RoutingPathLess)
    end
  end
end
