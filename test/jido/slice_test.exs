defmodule JidoTest.SliceTest do
  use ExUnit.Case, async: true

  describe "compile-time validation" do
    test "raises CompileError when name is missing" do
      assert_raise CompileError, ~r/required/i, fn ->
        Code.compile_string("""
        defmodule JidoTest.SliceTest.NoName do
          use Jido.Slice, path: :x
        end
        """)
      end
    end

    test "raises CompileError when path is missing" do
      assert_raise CompileError, ~r/required/i, fn ->
        Code.compile_string("""
        defmodule JidoTest.SliceTest.NoPath do
          use Jido.Slice, name: "no_path"
        end
        """)
      end
    end

    test "raises CompileError on invalid name" do
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule JidoTest.SliceTest.BadName do
          use Jido.Slice, name: "has spaces", path: :x
        end
        """)
      end
    end
  end

  describe "accessors" do
    defmodule MinimalSlice do
      @moduledoc false
      use Jido.Slice, name: "minimal", path: :minimal
    end

    defmodule FullSlice do
      @moduledoc false
      use Jido.Slice,
        name: "full",
        path: :full,
        description: "A test slice",
        category: "test",
        vsn: "0.1.0",
        tags: ["a", "b"],
        capabilities: [:speak],
        requires: [{:config, :token}],
        signal_routes: [{"send", JidoTest.PluginTestAction}],
        schema: Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)}),
        config_schema: Zoi.object(%{enabled: Zoi.boolean() |> Zoi.default(true)})
    end

    test "minimal slice exposes name and path" do
      assert MinimalSlice.name() == "minimal"
      assert MinimalSlice.path() == :minimal
      assert MinimalSlice.actions() == []
      assert MinimalSlice.tags() == []
      assert MinimalSlice.capabilities() == []
      assert MinimalSlice.signal_routes() == []
      assert MinimalSlice.singleton?() == false
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
      use Jido.Slice,
        name: "schema",
        path: :schema,
        schema: Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
    end

    defmodule SchemaAgent do
      @moduledoc false
      use Jido.Agent,
        name: "schema_agent",
        path: :app,
        default_plugins: false,
        plugins: [JidoTest.SliceTest.SchemaSlice]
    end

    test "Agent.new/1 seeds slice state from the schema's defaults" do
      agent = SchemaAgent.new()
      assert agent.state.schema == %{counter: 0}
    end

    test "per-agent config merges into the slice on top of defaults" do
      defmodule SchemaAgentConfigured do
        @moduledoc false
        use Jido.Agent,
          name: "schema_agent_configured",
          path: :app,
          default_plugins: false,
          plugins: [{JidoTest.SliceTest.SchemaSlice, %{counter: 42}}]
      end

      agent = SchemaAgentConfigured.new()
      assert agent.state.schema == %{counter: 42}
    end
  end
end
