defmodule Jido.Dsl.PluginTest do
  use ExUnit.Case, async: true

  # Cover the plugin DSL's combination of slice surface + middleware
  # behaviour. The plugin DSL re-exports `Jido.Dsl.Slice.sections/0`, so
  # every section the slice DSL exposes is also available inside a
  # `use Jido.Plugin` module — this test asserts that, and also
  # verifies the simultaneous `__jido_slice__/0` + `__jido_plugin__/0`
  # markers + `Jido.Middleware` behaviour the spec calls out as a
  # regression.

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
    test "__jido_slice__/0 returns true" do
      assert SimplePlugin.__jido_slice__() == true
      assert FullPlugin.__jido_slice__() == true
    end

    test "__jido_plugin__/0 returns true" do
      assert SimplePlugin.__jido_plugin__() == true
      assert FullPlugin.__jido_plugin__() == true
    end

    test "module implements Jido.Middleware behaviour" do
      behaviours =
        FullPlugin.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Jido.Middleware in behaviours
    end

    test "user-defined on_signal/4 is callable" do
      assert function_exported?(FullPlugin, :on_signal, 4)
    end

    test "all three (slice marker, plugin marker, middleware behaviour) hold simultaneously" do
      # Per task 0035 spec: the plugin must expose all three identities
      # at the same time, since the agent's WalkExtensions transformer
      # uses each in different code paths.
      assert FullPlugin.__jido_slice__() == true
      assert FullPlugin.__jido_plugin__() == true

      behaviours =
        FullPlugin.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Jido.Middleware in behaviours
    end
  end

  describe "plugin DSL re-exports slice sections" do
    test "Jido.Dsl.Plugin.sections/0 returns the same list as Jido.Dsl.Slice.sections/0" do
      assert Jido.Dsl.Plugin.sections() == Jido.Dsl.Slice.sections()
    end

    test "plugin module exposes the same accessor surface as a slice" do
      assert FullPlugin.name() == "full_plugin"
      assert FullPlugin.path() == :full_plugin
      assert FullPlugin.description() == "A plugin with slice + middleware halves"
      assert FullPlugin.actions() == [JidoTest.PluginTestAction]
      assert FullPlugin.signal_routes() == [{"plugin.fired", JidoTest.PluginTestAction}]
      assert FullPlugin.capabilities() == [:plugin_capability]
      assert is_struct(FullPlugin.schema())
    end

    test "manifest/0 returns a Jido.Plugin.Manifest" do
      assert %Jido.Plugin.Manifest{} = FullPlugin.manifest()
    end
  end

  describe "agent integration with plugins" do
    defmodule PluginAgent do
      @moduledoc false
      use Jido.Agent,
        extensions: [Jido.Dsl.PluginTest.FullPlugin],
        default_slices: false

      agent do
        name "plugin_agent"
        path :domain
      end
    end

    test "plugin appears in plugins/0, not slices/0 or middleware/0" do
      assert FullPlugin in PluginAgent.plugins()
      refute FullPlugin in PluginAgent.slices()
      refute Enum.any?(PluginAgent.middleware(), &match?({FullPlugin, _}, &1))
    end

    test "plugin's schema is merged into the agent's seed state" do
      agent = PluginAgent.new()
      assert agent.state.full_plugin == %{enabled: true}
    end
  end

  describe "task 0029 enforcement (relaxed in task 0034 via explicit `as:`)" do
    test "extensions: [{Plugin, as: :slice}] force-mounts the plugin as a slice" do
      defmodule PluginAsSliceAgent do
        use Jido.Agent,
          extensions: [{Jido.Dsl.PluginTest.FullPlugin, [as: :slice]}],
          default_slices: false

        agent do
          name "plugin_as_slice_agent"
          path :domain
        end
      end

      # The new design allows the explicit `as: :slice` override. The
      # OLD task 0029 check ("plugin in slices: raises") is replaced by
      # the requirement that the user explicitly opt in via `as: :slice`.
      assert FullPlugin in PluginAsSliceAgent.slices()
      refute FullPlugin in PluginAsSliceAgent.plugins()
    end
  end
end
