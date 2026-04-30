defmodule Jido.Dsl.PluginTest do
  use ExUnit.Case, async: true

  # Cover the plugin DSL's combination of slice surface + middleware
  # behaviour. The plugin DSL re-exports `Jido.Dsl.Slice.sections/0`, so
  # every section the slice DSL exposes is also available inside a
  # `use Jido.Plugin` module — this test asserts that, and also
  # verifies the simultaneous `Spark.Dsl.is?(mod, Jido.Plugin)` /
  # `Spark.Dsl.is?(mod, Jido.Slice)` identities + `Jido.Middleware`
  # behaviour the spec calls out as a regression.

  alias Jido.Dsl.Agent.Info, as: AgentInfo
  alias Jido.Dsl.Plugin.Info, as: PluginInfo

  Code.ensure_compiled!(JidoTest.PluginTestAction)

  defmodule SimplePlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "simple_plugin"
      path :simple_plugin
    end
  end

  defmodule FullPlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "full_plugin"
      path :full_plugin
      description "A plugin with slice + middleware halves"
      schema Zoi.object(%{enabled: Zoi.boolean() |> Zoi.default(true)})
    end

    signal_routes do
      route "plugin.fired", JidoTest.PluginTestAction
    end

    capabilities do
      capability :plugin_capability
    end

    @impl Jido.Middleware
    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  describe "plugin markers and behaviour" do
    test "Spark.Dsl.is?(mod, Jido.Plugin) is true for plugin modules" do
      assert Spark.Dsl.is?(SimplePlugin, Jido.Plugin)
      assert Spark.Dsl.is?(FullPlugin, Jido.Plugin)
    end

    test "module implements Jido.Middleware behaviour" do
      behaviours =
        FullPlugin.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Jido.Middleware in behaviours
    end

    test "user-defined on_signal/4 is callable" do
      assert function_exported?(FullPlugin, :on_signal, 4)
    end

    test "plugin identity + middleware behaviour hold simultaneously" do
      # Per task 0035 spec: the plugin must expose its plugin identity
      # plus the middleware behaviour at the same time, since the
      # agent's WalkExtensions transformer uses each in different
      # code paths.
      assert Spark.Dsl.is?(FullPlugin, Jido.Plugin)

      behaviours =
        FullPlugin.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Jido.Middleware in behaviours
    end
  end

  describe "plugin DSL re-exports slice sections" do
    test "Jido.Dsl.Plugin.sections/0 returns the same list as Jido.Dsl.Slice.sections/0" do
      assert Jido.Dsl.Plugin.sections() == Jido.Dsl.Slice.sections()
    end

    test "plugin module exposes the same accessor surface as a slice via Plugin.Info" do
      assert PluginInfo.name(FullPlugin) == "full_plugin"
      assert PluginInfo.path(FullPlugin) == :full_plugin
      assert PluginInfo.description(FullPlugin) == "A plugin with slice + middleware halves"
      assert PluginInfo.actions(FullPlugin) == [JidoTest.PluginTestAction]
      assert PluginInfo.signal_routes(FullPlugin) == [{"plugin.fired", JidoTest.PluginTestAction}]
      assert PluginInfo.capabilities(FullPlugin) == [:plugin_capability]
      assert is_struct(PluginInfo.schema(FullPlugin))
    end
  end

  describe "agent integration with plugins" do
    defmodule PluginAgent do
      @moduledoc false
      use Jido.Agent,
        middleware: [Jido.Dsl.PluginTest.FullPlugin],
        default_slices: false

      agent do
        name "plugin_agent"
      end

      slices do
        slice(:full_plugin, Jido.Dsl.PluginTest.FullPlugin)
      end
    end

    test "plugin appears in both plugins/1 and middleware/1 (its slice and middleware halves)" do
      # task 0053: plugins are deliberately registered in BOTH `slices do …`
      # (for path/options) and `middleware: […]` (for wrap-chain ordering).
      assert FullPlugin in AgentInfo.plugins(PluginAgent)
      refute FullPlugin in AgentInfo.slices(PluginAgent)
      assert Enum.any?(AgentInfo.middleware(PluginAgent), &match?({FullPlugin, _}, &1))
    end

    test "plugin's schema is merged into the agent's seed state" do
      agent = PluginAgent.new()
      assert agent.state.full_plugin == %{enabled: true}
    end
  end
end
