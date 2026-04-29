defmodule Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutesTest do
  @moduledoc """
  Regression coverage for the `HasSchemaAndRoutes` verifier wired into
  `Jido.Dsl.Slice`. A slice without a `schema:` or without at least one
  `signal_routes` entry must fail compilation with a
  `Spark.Error.DslError` naming the missing piece.
  """

  use ExUnit.Case, async: true

  Code.ensure_compiled!(JidoTest.PluginTestAction)

  alias Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutes

  describe "verify/1" do
    test "rejects a slice that omits both `schema:` and `signal_routes`" do
      dsl_state = build_state(schema: nil, routes: [])

      assert {:error, %Spark.Error.DslError{path: [:slice, :schema], message: message}} =
               HasSchemaAndRoutes.verify(dsl_state)

      assert message =~ "Slice must declare a `schema:`"
    end

    test "rejects a slice with `schema:` but no routes" do
      dsl_state =
        build_state(schema: Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)}), routes: [])

      assert {:error, %Spark.Error.DslError{path: [:signal_routes], message: message}} =
               HasSchemaAndRoutes.verify(dsl_state)

      assert message =~ "Slice must declare at least one route"
    end

    test "rejects a slice whose schema is the literal empty list" do
      dsl_state = build_state(schema: [], routes: [])

      assert {:error, %Spark.Error.DslError{path: [:slice, :schema]}} =
               HasSchemaAndRoutes.verify(dsl_state)
    end

    test "accepts a slice with both `schema:` and at least one route" do
      dsl_state =
        build_state(
          schema: Zoi.object(%{value: Zoi.any() |> Zoi.optional()}),
          routes: [%Jido.Slice.RouteEntry{type: "go", action: JidoTest.PluginTestAction}]
        )

      assert HasSchemaAndRoutes.verify(dsl_state) == :ok
    end
  end

  describe "@after_verify hook (compile-time integration)" do
    test "the wired-in verifier blocks a no-schema/no-routes slice from compiling cleanly" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutesTest.NoSchemaNoRoutes do
            use Jido.Slice

            slice do
              name "no_schema_no_routes"
              path :no_schema_no_routes
            end
          end
          """)
        end)

      assert output =~ "Slice must declare a `schema:`"
    end

    test "the wired-in verifier blocks a no-routes slice from compiling cleanly" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutesTest.SchemaNoRoutes do
            use Jido.Slice

            slice do
              name "schema_no_routes"
              path :schema_no_routes
              schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
            end
          end
          """)
        end)

      assert output =~ "Slice must declare at least one route"
    end

    test "a happy-path slice compiles cleanly with no warnings" do
      defmodule HappyPathSlice do
        @moduledoc false
        use Jido.Slice

        slice do
          name "happy_path"
          path :happy_path
          schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
        end

        signal_routes do
          route "happy_path.go", JidoTest.PluginTestAction
        end
      end

      assert Jido.Dsl.Slice.Info.path(HappyPathSlice) == :happy_path

      assert Jido.Dsl.Slice.Info.signal_routes(HappyPathSlice) == [
               {"happy_path.go", JidoTest.PluginTestAction}
             ]
    end
  end

  defp build_state(opts) do
    schema = Keyword.fetch!(opts, :schema)
    routes = Keyword.fetch!(opts, :routes)

    %{
      [:slice] => %{opts: [schema: schema]},
      [:signal_routes] => %{entities: routes}
    }
  end
end
