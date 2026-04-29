defmodule JidoTest.Agent.SlicesAttachmentTest do
  use ExUnit.Case, async: true

  alias Jido.Dsl.Agent.Info, as: AgentInfo

  # ===========================================================================
  # Fixtures: bare slices, plugins, non-slices
  # ===========================================================================

  defmodule SimpleSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "simple_slice"
      path :simple

      schema Zoi.object(%{
               counter: Zoi.integer() |> Zoi.default(0),
               label: Zoi.string() |> Zoi.default("default")
             })
    end

    signal_routes do
      route "simple.noop", JidoTest.PluginTestAction
    end

    capabilities do
      capability :simple
    end
  end

  defmodule RoutedSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "routed_slice"
      path :routed
      schema Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)})
    end

    signal_routes do
      route "absolute.path.one", JidoTest.PluginTestAction
      route "absolute.path.two", JidoTest.PluginTestAction
    end
  end

  defmodule OtherSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "other_slice"
      path :other
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "other.noop", JidoTest.PluginTestAction
    end
  end

  defmodule BarePlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "bare_plugin"
      path :bare_plugin
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "bare_plugin.noop", JidoTest.PluginTestAction
    end
  end

  defmodule NotASlice do
    @moduledoc false
  end

  # ===========================================================================
  # Successful attachment
  # ===========================================================================

  describe "bare slice attachment" do
    test "use Jido.Agent, slices: [SomeSlice] mounts the slice at its path() with seeded defaults" do
      defmodule AgentBareSlice do
        use Jido.Agent,
          extensions: [SimpleSlice],
          default_slices: false

        agent do
          name "bare_slice_agent"
        end
      end

      agent = AgentBareSlice.new()

      assert agent.state.simple == %{counter: 0, label: "default"}
      assert SimpleSlice in AgentInfo.slices(AgentBareSlice)
    end

    test "use Jido.Agent, slices: [{SomeSlice, key: value}] seeds the config into slice state" do
      defmodule AgentConfiguredSlice do
        use Jido.Agent,
          extensions: [{SimpleSlice, %{counter: 42, label: "from_config"}}],
          default_slices: false

        agent do
          name "configured_slice_agent"
        end
      end

      agent = AgentConfiguredSlice.new()

      assert agent.state.simple == %{counter: 42, label: "from_config"}
    end

    test "slice config in keyword form is also accepted" do
      defmodule AgentKeywordSlice do
        use Jido.Agent,
          extensions: [{SimpleSlice, [counter: 7]}],
          default_slices: false

        agent do
          name "keyword_slice_agent"
        end
      end

      agent = AgentKeywordSlice.new()

      assert agent.state.simple.counter == 7
    end

    test "slice's signal_routes register at the agent with absolute paths (no prefix)" do
      defmodule AgentRoutedSlice do
        use Jido.Agent,
          extensions: [RoutedSlice],
          default_slices: false

        agent do
          name "routed_slice_agent"
        end
      end

      route_paths =
        AgentRoutedSlice
        |> AgentInfo.plugin_routes()
        |> Enum.map(fn {path, _action, _priority} -> path end)

      assert "absolute.path.one" in route_paths
      assert "absolute.path.two" in route_paths
    end

    test "multiple bare slices compose at distinct paths" do
      defmodule AgentMultipleSlices do
        use Jido.Agent,
          extensions: [SimpleSlice, OtherSlice],
          default_slices: false

        agent do
          name "multiple_slices_agent"
        end
      end

      modules = AgentInfo.slices(AgentMultipleSlices)
      assert SimpleSlice in modules
      assert OtherSlice in modules

      agent = AgentMultipleSlices.new()
      assert Map.has_key?(agent.state, :simple)
      assert Map.has_key?(agent.state, :other)
    end

    test "slice capabilities are aggregated" do
      defmodule AgentSliceCaps do
        use Jido.Agent,
          extensions: [SimpleSlice],
          default_slices: false

        agent do
          name "slice_caps_agent"
        end
      end

      assert :simple in AgentInfo.capabilities(AgentSliceCaps)
    end
  end

  # ===========================================================================
  # Path conflicts
  # ===========================================================================

  describe "path conflict detection" do
    test "path collision between agent's path: and a slices: entry emits a warning" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule AgentPathConflict do
            use Jido.Agent,
              extensions: [SimpleSlice],
              default_slices: false

            agent do
              name "path_conflict_agent"
              path :simple
            end
          end
        end)

      assert stderr =~ ~r/[Dd]uplicate.*paths/
    end

    test "path collision between two slices: entries emits a warning" do
      defmodule SimpleSliceDuplicate do
        @moduledoc false
        use Jido.Slice

        slice do
          name "simple_dup"
          path :simple
          schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
        end

        signal_routes do
          route "simple_dup.noop", JidoTest.PluginTestAction
        end
      end

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule AgentSliceConflict do
            use Jido.Agent,
              extensions: [SimpleSlice, SimpleSliceDuplicate],
              default_slices: false

            agent do
              name "slice_conflict_agent"
            end
          end
        end)

      assert stderr =~ ~r/[Dd]uplicate.*paths/
    end
  end

  # ===========================================================================
  # Validation: rejects plugins, rejects non-slices
  # ===========================================================================

  describe "slices: validation" do
    test "force-mounting a bare slice as :plugin raises a clear message" do
      assert_raise RuntimeError, ~r/is not a `use Jido.Plugin` module/, fn ->
        defmodule AgentRejectsBareAsPlugin do
          use Jido.Agent,
            extensions: [{SimpleSlice, [as: :plugin]}],
            default_slices: false

          agent do
            name "rejects_bare_as_plugin_agent"
          end
        end
      end
    end

    test "putting a non-slice module in extensions: raises with a clear message" do
      assert_raise RuntimeError,
                   ~r/is not a Jido\.Plugin, Jido\.Slice, or Jido\.Middleware/,
                   fn ->
                     defmodule AgentRejectsNonSlice do
                       use Jido.Agent,
                         extensions: [NotASlice],
                         default_slices: false

                       agent do
                         name "rejects_non_slice_agent"
                       end
                     end
                   end
    end
  end

  # ===========================================================================
  # Renamed framework singletons attach via default-slices path
  # ===========================================================================

  describe "renamed framework singletons" do
    test "Jido.Identity.Slice attaches via the default-slices path" do
      defmodule AgentDefaultSlices do
        use Jido.Agent

        agent do
          name "default_slices_agent"
        end
      end

      modules = AgentInfo.slices(AgentDefaultSlices)
      assert Jido.Identity.Slice in modules
      assert Jido.Memory.Slice in modules
      assert Jido.Thread.Slice in modules
    end
  end
end
