defmodule Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutesTest do
  @moduledoc """
  Regression coverage for the `HasSchemaAndRoutes` verifier wired into
  `Jido.Dsl.Slice`. A slice without a `schema:` must fail compilation
  with a `Spark.Error.DslError`.
  """

  use ExUnit.Case, async: true

  Code.ensure_compiled!(JidoTest.PluginTestAction)

  alias Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutes

  describe "verify/1" do
    test "rejects a slice that omits `schema:`" do
      dsl_state = build_state(schema: nil)

      assert {:error, %Spark.Error.DslError{path: [:slice, :schema], message: message}} =
               HasSchemaAndRoutes.verify(dsl_state)

      assert message =~ "Slice must declare a `schema:`"
    end

    test "rejects a slice whose schema is the literal empty list" do
      dsl_state = build_state(schema: [])

      assert {:error, %Spark.Error.DslError{path: [:slice, :schema]}} =
               HasSchemaAndRoutes.verify(dsl_state)
    end

    test "accepts a slice with `schema:`" do
      dsl_state =
        build_state(schema: Zoi.object(%{value: Zoi.any() |> Zoi.optional()}))

      assert HasSchemaAndRoutes.verify(dsl_state) == :ok
    end
  end

  describe "@after_verify hook (compile-time integration)" do
    test "the wired-in verifier blocks a no-schema slice from compiling cleanly" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule Jido.Dsl.Slice.Verifiers.HasSchemaAndRoutesTest.NoSchemaSlice do
            use Jido.Slice

            slice do
              name "no_schema"
            end
          end
          """)
        end)

      assert output =~ "Slice must declare a `schema:`"
    end

    test "a happy-path slice compiles cleanly with no warnings" do
      defmodule HappyPathSlice do
        @moduledoc false
        use Jido.Slice

        slice do
          name "happy_path"
          schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
        end

        signal_routes do
          route "happy_path.go", JidoTest.PluginTestAction
        end
      end

      assert Jido.Dsl.Slice.Info.signal_routes(HappyPathSlice) == [
               {"happy_path.go", JidoTest.PluginTestAction}
             ]
    end
  end

  defp build_state(opts) do
    schema = Keyword.fetch!(opts, :schema)

    %{[:slice] => %{opts: [schema: schema]}}
  end
end
