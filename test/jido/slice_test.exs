defmodule JidoTest.SliceTest do
  use ExUnit.Case, async: true

  describe "compile-time validation" do
    test "raises CompileError when name is missing" do
      assert_raise Spark.Error.DslError, ~r/required :name option/, fn ->
        Code.compile_string("""
        defmodule JidoTest.SliceTest.NoName do
          use Jido.Slice

          slice do
            path :x
          end
        end
        """)
      end
    end

    test "raises CompileError when path is missing" do
      assert_raise Spark.Error.DslError, ~r/required :path option/, fn ->
        Code.compile_string("""
        defmodule JidoTest.SliceTest.NoPath do
          use Jido.Slice

          slice do
            name "no_path"
          end
        end
        """)
      end
    end

    test "raises CompileError on invalid name" do
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule JidoTest.SliceTest.BadName do
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

  describe "accessors" do
    defmodule MinimalSlice do
      @moduledoc false
      use Jido.Slice

      slice do
        name "minimal"
        path :minimal
      end
    end

    defmodule FullSlice do
      @moduledoc false
      use Jido.Slice

      slice do
        name "full"
        path :full
        description "A test slice"
        category "test"
        vsn "0.1.0"
        tags ["a", "b"]
        schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
        config_schema Zoi.object(%{enabled: Zoi.boolean() |> Zoi.default(true)})
      end

      capabilities do
        capability :speak
      end

      requires do
        requires :config, :token
      end

      signal_routes do
        route "send", JidoTest.PluginTestAction
      end
    end

    test "minimal slice exposes name and path" do
      assert MinimalSlice.name() == "minimal"
      assert MinimalSlice.path() == :minimal
      assert MinimalSlice.actions() == []
      assert MinimalSlice.tags() == []
      assert MinimalSlice.capabilities() == []
      assert MinimalSlice.signal_routes() == []
    end

    test "full slice exposes every metadata field" do
      assert FullSlice.name() == "full"
      assert FullSlice.path() == :full
      assert FullSlice.description() == "A test slice"
      assert FullSlice.category() == "test"
      assert FullSlice.vsn() == "0.1.0"
      assert FullSlice.tags() == ["a", "b"]
      assert FullSlice.capabilities() == [:speak]
      assert FullSlice.requires() == [{:config, :token}]
      assert FullSlice.signal_routes() == [{"send", JidoTest.PluginTestAction}]
      assert is_struct(FullSlice.schema())
      assert is_struct(FullSlice.config_schema())
    end

    test "manifest/0 returns a Jido.Plugin.Manifest with path populated" do
      manifest = FullSlice.manifest()
      assert %Jido.Plugin.Manifest{} = manifest
      assert manifest.path == :full
      assert manifest.name == "full"
      assert manifest.signal_routes == [{"send", JidoTest.PluginTestAction}]
    end

    test "plugin_spec/1 returns a Jido.Plugin.Spec with config merged" do
      spec = FullSlice.plugin_spec(%{enabled: false})
      assert %Jido.Plugin.Spec{} = spec
      assert spec.path == :full
      assert spec.config == %{enabled: false}
    end
  end

  describe "schema defaults" do
    defmodule SchemaSlice do
      @moduledoc false
      use Jido.Slice

      slice do
        name "schema"
        path :schema
        schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
      end
    end

    defmodule SchemaAgent do
      @moduledoc false
      use Jido.Agent,
        extensions: [JidoTest.SliceTest.SchemaSlice],
        default_slices: false

      agent do
        name "schema_agent"
        path :app
      end
    end

    test "Agent.new/1 seeds slice state from the schema's defaults" do
      agent = SchemaAgent.new()
      assert agent.state.schema == %{counter: 0}
    end

    test "per-agent config merges into the slice on top of defaults" do
      defmodule SchemaAgentConfigured do
        @moduledoc false
        use Jido.Agent,
          extensions: [{JidoTest.SliceTest.SchemaSlice, %{counter: 42}}],
          default_slices: false

        agent do
          name "schema_agent_configured"
          path :app
        end
      end

      agent = SchemaAgentConfigured.new()
      assert agent.state.schema == %{counter: 42}
    end
  end
end
