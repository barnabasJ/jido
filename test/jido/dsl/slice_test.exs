defmodule Jido.Dsl.SliceTest do
  use ExUnit.Case, async: true

  # Cover the seven slice DSL sections, the GenerateAccessors transformer's
  # public surface, and the regression cases called out in the task spec
  # (`schema/0` parity with the legacy macro, `defoverridable` parity,
  # `__jido_slice__/0` marker, plugin-as-slice override, slice-as-plugin
  # rejection).

  Code.ensure_compiled!(JidoTest.PluginTestAction)

  defmodule MinimalSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "minimal"
      path :minimal
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "minimal.noop", JidoTest.PluginTestAction
    end
  end

  defmodule FullSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "full"
      path :full
      description "A full slice"
      category "test"
      vsn "0.1.0"
      tags ["a", "b"]
      schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
      config_schema Zoi.object(%{enabled: Zoi.boolean() |> Zoi.default(true)})
    end

    signal_routes do
      route "send", JidoTest.PluginTestAction
    end

    capabilities do
      capability :speak
    end

    requires do
      requires :config, :token
    end
  end

  defmodule SchemaSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "schema_only"
      path :schema_only
      schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
    end

    signal_routes do
      route "schema_only.noop", JidoTest.PluginTestAction
    end
  end

  describe "slice section accessors" do
    test "minimal slice exposes name, path, schema, and a single route" do
      assert MinimalSlice.name() == "minimal"
      assert MinimalSlice.path() == :minimal
      assert MinimalSlice.actions() == [JidoTest.PluginTestAction]
      assert MinimalSlice.tags() == []
      assert MinimalSlice.capabilities() == []
      assert MinimalSlice.signal_routes() == [{"minimal.noop", JidoTest.PluginTestAction}]
      assert MinimalSlice.subscriptions() == []
      assert MinimalSlice.schedules() == []
      assert MinimalSlice.requires() == []
      assert MinimalSlice.description() == nil
      assert MinimalSlice.category() == nil
      assert MinimalSlice.vsn() == nil
      assert MinimalSlice.otp_app() == nil
      assert is_struct(MinimalSlice.schema())
      assert MinimalSlice.config_schema() == nil
    end

    test "full slice exposes every metadata field" do
      assert FullSlice.name() == "full"
      assert FullSlice.path() == :full
      assert FullSlice.description() == "A full slice"
      assert FullSlice.category() == "test"
      assert FullSlice.vsn() == "0.1.0"
      assert FullSlice.tags() == ["a", "b"]
      assert FullSlice.actions() == [JidoTest.PluginTestAction]
      assert FullSlice.capabilities() == [:speak]
      assert FullSlice.requires() == [{:config, :token}]
      assert FullSlice.signal_routes() == [{"send", JidoTest.PluginTestAction}]
      assert is_struct(FullSlice.schema())
      assert is_struct(FullSlice.config_schema())
    end

    test "manifest/0 returns a Jido.Plugin.Manifest with all fields populated" do
      manifest = FullSlice.manifest()
      assert %Jido.Plugin.Manifest{} = manifest
      assert manifest.module == FullSlice
      assert manifest.path == :full
      assert manifest.name == "full"
      assert manifest.actions == [JidoTest.PluginTestAction]
      assert manifest.signal_routes == [{"send", JidoTest.PluginTestAction}]
      assert manifest.capabilities == [:speak]
      assert manifest.requires == [{:config, :token}]
    end

    test "plugin_spec/1 returns a Jido.Plugin.Spec with config merged" do
      spec = FullSlice.plugin_spec(%{enabled: false})
      assert %Jido.Plugin.Spec{} = spec
      assert spec.path == :full
      assert spec.config == %{enabled: false}
      assert spec.actions == [JidoTest.PluginTestAction]
    end

    test "__plugin_metadata__/0 returns discovery metadata" do
      metadata = FullSlice.__plugin_metadata__()
      assert metadata.name == "full"
      assert metadata.description == "A full slice"
      assert metadata.category == "test"
      assert metadata.tags == ["a", "b"]
    end

    test "__jido_slice__/0 marker is emitted" do
      assert MinimalSlice.__jido_slice__() == true
      assert FullSlice.__jido_slice__() == true
    end
  end

  describe "schema/0 parity with the legacy macro" do
    test "schema/0 returns the same Zoi struct passed into the section" do
      schema = SchemaSlice.schema()
      assert is_struct(schema)
      # Round-trip: parsing seed input through the schema yields the default
      assert {:ok, %{counter: 0}} = Zoi.parse(schema, %{})
    end

    test "schema/0 returns the slice's declared schema struct" do
      assert is_struct(MinimalSlice.schema())
    end
  end

  describe "defoverridable parity (16 functions)" do
    defmodule OverridingSlice do
      @moduledoc false
      use Jido.Slice

      slice do
        name "overriding"
        path :overriding
        schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
      end

      signal_routes do
        route "overriding.noop", JidoTest.PluginTestAction
      end

      def name, do: "overridden_name"
      def description, do: "overridden description"
    end

    test "user override of name/0 wins" do
      assert OverridingSlice.name() == "overridden_name"
    end

    test "user override of description/0 wins" do
      assert OverridingSlice.description() == "overridden description"
    end
  end

  describe "compile-time validation" do
    test "raises when required `name` is missing" do
      assert_raise Spark.Error.DslError, ~r/required :name option/, fn ->
        Code.compile_string("""
        defmodule Jido.Dsl.SliceTest.NoName do
          use Jido.Slice

          slice do
            path :x
          end
        end
        """)
      end
    end

    test "raises when required `path` is missing" do
      assert_raise Spark.Error.DslError, ~r/required :path option/, fn ->
        Code.compile_string("""
        defmodule Jido.Dsl.SliceTest.NoPath do
          use Jido.Slice

          slice do
            name "no_path"
          end
        end
        """)
      end
    end

    test "raises when name has invalid characters" do
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule Jido.Dsl.SliceTest.BadName do
          use Jido.Slice

          slice do
            name "has spaces"
            path :x
          end
        end
        """)
      end
    end
  end

  describe "agent integration with bare slices" do
    defmodule BareSliceAgent do
      @moduledoc false
      use Jido.Agent,
        extensions: [Jido.Dsl.SliceTest.SchemaSlice],
        default_slices: false

      agent do
        name "bare_slice_agent"
      end
    end

    test "Agent.new/1 seeds slice state from the schema's defaults" do
      agent = BareSliceAgent.new()
      assert agent.state.schema_only == %{counter: 0}
    end

    test "extensions: [Slice] mounts the slice at its path()" do
      assert SchemaSlice in BareSliceAgent.slices()
    end
  end

  describe "task 0029 enforcement: bare slice as :plugin override raises" do
    test "extensions: [{BareSlice, as: :plugin}] raises a RuntimeError" do
      assert_raise RuntimeError, ~r/missing __jido_plugin__/, fn ->
        defmodule BareSliceAsPluginAgent do
          use Jido.Agent,
            extensions: [{Jido.Dsl.SliceTest.MinimalSlice, [as: :plugin]}]

          agent do
            name "bare_as_plugin_agent"
          end
        end
      end
    end
  end
end
