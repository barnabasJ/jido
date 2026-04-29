defmodule Jido.Dsl.SliceTest do
  use ExUnit.Case, async: true

  # Cover the seven slice DSL sections, the Info-module accessor
  # surface, and the regression cases called out in the task spec
  # (`schema/1` parity with the legacy macro,
  # `Spark.Dsl.is?(mod, Jido.Slice)` marker, plugin-as-slice override,
  # slice-as-plugin rejection).

  alias Jido.Dsl.Slice.Info, as: SliceInfo

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
      assert SliceInfo.name(MinimalSlice) == "minimal"
      assert SliceInfo.path(MinimalSlice) == :minimal
      assert SliceInfo.actions(MinimalSlice) == [JidoTest.PluginTestAction]
      assert SliceInfo.tags(MinimalSlice) == []
      assert SliceInfo.capabilities(MinimalSlice) == []

      assert SliceInfo.signal_routes(MinimalSlice) == [
               {"minimal.noop", JidoTest.PluginTestAction}
             ]

      assert SliceInfo.subscriptions(MinimalSlice) == []
      assert SliceInfo.schedules(MinimalSlice) == []
      assert SliceInfo.requires(MinimalSlice) == []
      assert SliceInfo.description(MinimalSlice) == nil
      assert SliceInfo.category(MinimalSlice) == nil
      assert SliceInfo.vsn(MinimalSlice) == nil
      assert SliceInfo.otp_app(MinimalSlice) == nil
      assert is_struct(SliceInfo.schema(MinimalSlice))
      assert SliceInfo.config_schema(MinimalSlice) == nil
    end

    test "full slice exposes every metadata field" do
      assert SliceInfo.name(FullSlice) == "full"
      assert SliceInfo.path(FullSlice) == :full
      assert SliceInfo.description(FullSlice) == "A full slice"
      assert SliceInfo.category(FullSlice) == "test"
      assert SliceInfo.vsn(FullSlice) == "0.1.0"
      assert SliceInfo.tags(FullSlice) == ["a", "b"]
      assert SliceInfo.actions(FullSlice) == [JidoTest.PluginTestAction]
      assert SliceInfo.capabilities(FullSlice) == [:speak]
      assert SliceInfo.requires(FullSlice) == [{:config, :token}]
      assert SliceInfo.signal_routes(FullSlice) == [{"send", JidoTest.PluginTestAction}]
      assert is_struct(SliceInfo.schema(FullSlice))
      assert is_struct(SliceInfo.config_schema(FullSlice))
    end

    test "Spark.Dsl.is?(mod, Jido.Slice) is true for slice modules" do
      assert Spark.Dsl.is?(MinimalSlice, Jido.Slice)
      assert Spark.Dsl.is?(FullSlice, Jido.Slice)
    end
  end

  describe "schema/1 parity with the legacy macro" do
    test "schema/1 returns the same Zoi struct passed into the section" do
      schema = SliceInfo.schema(SchemaSlice)
      assert is_struct(schema)
      # Round-trip: parsing seed input through the schema yields the default
      assert {:ok, %{counter: 0}} = Zoi.parse(schema, %{})
    end

    test "schema/1 returns the slice's declared schema struct" do
      assert is_struct(SliceInfo.schema(MinimalSlice))
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
      assert SchemaSlice in Jido.Dsl.Agent.Info.slices(BareSliceAgent)
    end
  end

  describe "task 0029 enforcement: bare slice as :plugin override raises" do
    test "extensions: [{BareSlice, as: :plugin}] raises with a useful message" do
      assert_raise RuntimeError, ~r/is not a `use Jido.Plugin` module/, fn ->
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
