defmodule JidoTest.Agent.SlicesAttachmentTest do
  use ExUnit.Case, async: true

  # ===========================================================================
  # Fixtures: bare slices, plugins, non-slices
  # ===========================================================================

  defmodule SimpleSlice do
    @moduledoc false
    use Jido.Slice,
      name: "simple_slice",
      path: :simple,
      actions: [],
      schema:
        Zoi.object(%{
          counter: Zoi.integer() |> Zoi.default(0),
          label: Zoi.string() |> Zoi.default("default")
        }),
      capabilities: [:simple]
  end

  defmodule RoutedSlice do
    @moduledoc false
    use Jido.Slice,
      name: "routed_slice",
      path: :routed,
      actions: [],
      schema: Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}),
      signal_routes: [
        {"absolute.path.one", JidoTest.PluginTestAction},
        {"absolute.path.two", JidoTest.PluginTestAction}
      ]
  end

  defmodule OtherSlice do
    @moduledoc false
    use Jido.Slice,
      name: "other_slice",
      path: :other,
      actions: []
  end

  defmodule BarePlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "bare_plugin",
      path: :bare_plugin,
      actions: []
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
          name: "bare_slice_agent",
          path: :domain,
          default_slices: false,
          slices: [SimpleSlice]
      end

      agent = AgentBareSlice.new()

      assert agent.state.simple == %{counter: 0, label: "default"}
      assert SimpleSlice in AgentBareSlice.slices()
    end

    test "use Jido.Agent, slices: [{SomeSlice, key: value}] seeds the config into slice state" do
      defmodule AgentConfiguredSlice do
        use Jido.Agent,
          name: "configured_slice_agent",
          path: :domain,
          default_slices: false,
          slices: [{SimpleSlice, %{counter: 42, label: "from_config"}}]
      end

      agent = AgentConfiguredSlice.new()

      assert agent.state.simple == %{counter: 42, label: "from_config"}
    end

    test "slice config in keyword form is also accepted" do
      defmodule AgentKeywordSlice do
        use Jido.Agent,
          name: "keyword_slice_agent",
          path: :domain,
          default_slices: false,
          slices: [{SimpleSlice, [counter: 7]}]
      end

      agent = AgentKeywordSlice.new()

      assert agent.state.simple.counter == 7
    end

    test "slice's signal_routes register at the agent with absolute paths (no prefix)" do
      defmodule AgentRoutedSlice do
        use Jido.Agent,
          name: "routed_slice_agent",
          path: :domain,
          default_slices: false,
          slices: [RoutedSlice]
      end

      route_paths =
        AgentRoutedSlice.plugin_routes()
        |> Enum.map(fn {path, _action, _priority} -> path end)

      assert "absolute.path.one" in route_paths
      assert "absolute.path.two" in route_paths
    end

    test "multiple bare slices compose at distinct paths" do
      defmodule AgentMultipleSlices do
        use Jido.Agent,
          name: "multiple_slices_agent",
          path: :domain,
          default_slices: false,
          slices: [SimpleSlice, OtherSlice]
      end

      modules = AgentMultipleSlices.slices()
      assert SimpleSlice in modules
      assert OtherSlice in modules

      agent = AgentMultipleSlices.new()
      assert Map.has_key?(agent.state, :simple)
      assert Map.has_key?(agent.state, :other)
    end

    test "slice capabilities are aggregated" do
      defmodule AgentSliceCaps do
        use Jido.Agent,
          name: "slice_caps_agent",
          path: :domain,
          default_slices: false,
          slices: [SimpleSlice]
      end

      assert :simple in AgentSliceCaps.capabilities()
    end
  end

  # ===========================================================================
  # Path conflicts
  # ===========================================================================

  describe "path conflict detection" do
    test "path collision between agent's path: and a slices: entry raises CompileError" do
      assert_raise CompileError, ~r/Duplicate slice paths/, fn ->
        defmodule AgentPathConflict do
          use Jido.Agent,
            name: "path_conflict_agent",
            path: :simple,
            default_slices: false,
            slices: [SimpleSlice]
        end
      end
    end

    test "path collision between two slices: entries raises CompileError" do
      defmodule SimpleSliceDuplicate do
        @moduledoc false
        use Jido.Slice,
          name: "simple_dup",
          path: :simple,
          actions: []
      end

      assert_raise CompileError, ~r/Duplicate slice paths/, fn ->
        defmodule AgentSliceConflict do
          use Jido.Agent,
            name: "slice_conflict_agent",
            path: :domain,
            default_slices: false,
            slices: [SimpleSlice, SimpleSliceDuplicate]
        end
      end
    end
  end

  # ===========================================================================
  # Validation: rejects plugins, rejects non-slices
  # ===========================================================================

  describe "slices: validation" do
    test "putting a use Jido.Plugin module in slices: raises with a clear message" do
      assert_raise CompileError, ~r/is a Plugin .*Plugins go in `plugins:`/s, fn ->
        defmodule AgentRejectsPlugin do
          use Jido.Agent,
            name: "rejects_plugin_agent",
            path: :domain,
            default_slices: false,
            slices: [BarePlugin]
        end
      end
    end

    test "putting a non-slice module in slices: raises with a clear message" do
      assert_raise CompileError, ~r/is not a Jido\.Slice; do `use Jido\.Slice`/, fn ->
        defmodule AgentRejectsNonSlice do
          use Jido.Agent,
            name: "rejects_non_slice_agent",
            path: :domain,
            default_slices: false,
            slices: [NotASlice]
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
        use Jido.Agent,
          name: "default_slices_agent",
          path: :domain
      end

      modules = AgentDefaultSlices.slices()
      assert Jido.Identity.Slice in modules
      assert Jido.Memory.Slice in modules
      assert Jido.Thread.Slice in modules
    end
  end
end
