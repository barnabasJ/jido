defmodule JidoTest.SliceTest do
  use ExUnit.Case, async: true

  describe "compile-time validation" do
    test "raises CompileError when name is missing" do
      assert_raise Spark.Error.DslError, ~r/required :name option/, fn ->
        Code.compile_string("""
        defmodule JidoTest.SliceTest.NoName do
          use Jido.Slice

          slice do
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

    alias Jido.Dsl.Slice.Info, as: SliceInfo

    test "minimal slice exposes name and path via Info" do
      assert SliceInfo.name(MinimalSlice) == "minimal"
      assert SliceInfo.actions(MinimalSlice) == [JidoTest.PluginTestAction]
      assert SliceInfo.tags(MinimalSlice) == []
      assert SliceInfo.capabilities(MinimalSlice) == []

      assert SliceInfo.signal_routes(MinimalSlice) == [
               {"minimal.noop", JidoTest.PluginTestAction}
             ]
    end

    test "full slice exposes every metadata field via Info" do
      assert SliceInfo.name(FullSlice) == "full"
      assert SliceInfo.description(FullSlice) == "A test slice"
      assert SliceInfo.category(FullSlice) == "test"
      assert SliceInfo.vsn(FullSlice) == "0.1.0"
      assert SliceInfo.tags(FullSlice) == ["a", "b"]
      assert SliceInfo.capabilities(FullSlice) == [:speak]
      assert SliceInfo.requires(FullSlice) == [{:config, :token}]
      assert SliceInfo.signal_routes(FullSlice) == [{"send", JidoTest.PluginTestAction}]
      assert is_struct(SliceInfo.schema(FullSlice))
      assert is_struct(SliceInfo.config_schema(FullSlice))
    end
  end

  describe "schema defaults" do
    defmodule SchemaSlice do
      @moduledoc false
      use Jido.Slice

      slice do
        name "schema"
        schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
      end

      signal_routes do
        route "schema.noop", JidoTest.PluginTestAction
      end
    end

    defmodule SchemaAgent do
      @moduledoc false
      use Jido.Agent,
        default_slices: false

      agent do
        name "schema_agent"
      end

      slices do
        slice(:schema, JidoTest.SliceTest.SchemaSlice)
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
          default_slices: false

        agent do
          name "schema_agent_configured"
        end

        slices do
          slice(:schema, JidoTest.SliceTest.SchemaSlice, options: [counter: 42])
        end
      end

      agent = SchemaAgentConfigured.new()
      assert agent.state.schema == %{counter: 42}
    end
  end
end
