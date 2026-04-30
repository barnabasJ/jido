defmodule Jido.Dsl.MiddlewareTest do
  use ExUnit.Case, async: true

  # Cover the minimal middleware DSL: a single `middleware do … end`
  # section for declaring `:description` and `:schema`. Most middleware
  # don't need shape beyond the `on_signal/4` callback — the DSL is
  # optional metadata.

  defmodule MinimalMiddleware do
    @moduledoc false
    use Jido.Middleware

    @impl true
    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  defmodule ConfigurableMiddleware do
    @moduledoc false
    use Jido.Middleware

    middleware do
      description "Retries on transient failures."

      schema max_retries: [type: :pos_integer, default: 3],
             backoff_ms: [type: :pos_integer, default: 100]
    end

    @impl true
    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  describe "middleware behaviour" do
    test "minimal middleware implements Jido.Middleware behaviour" do
      behaviours =
        MinimalMiddleware.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Middleware in behaviours
    end

    test "user-defined on_signal/4 is exported" do
      assert function_exported?(MinimalMiddleware, :on_signal, 4)
    end

    test "bare middleware is not classified as a plugin or slice host" do
      refute Spark.Dsl.is?(MinimalMiddleware, Jido.Plugin)
      refute Spark.Dsl.is?(MinimalMiddleware, Jido.Slice)
    end
  end

  describe "middleware DSL section" do
    test "configurable middleware compiles" do
      assert function_exported?(ConfigurableMiddleware, :on_signal, 4)
    end

    test "Jido.Dsl.Middleware exposes a `:middleware` section" do
      section_names = Enum.map(Jido.Dsl.Middleware.sections(), & &1.name)
      assert :middleware in section_names
    end
  end

  describe "agent integration with middleware" do
    defmodule MiddlewareAgent do
      @moduledoc false
      use Jido.Agent,
        middleware: [Jido.Dsl.MiddlewareTest.MinimalMiddleware],
        default_slices: false

      agent do
        name "middleware_agent"
      end
    end

    test "middleware appears in middleware/1, not plugins/1 or slices/1" do
      assert Enum.any?(
               Jido.Dsl.Agent.Info.middleware(MiddlewareAgent),
               &match?({MinimalMiddleware, _}, &1)
             )

      refute MinimalMiddleware in Jido.Dsl.Agent.Info.plugins(MiddlewareAgent)
      refute MinimalMiddleware in Jido.Dsl.Agent.Info.slices(MiddlewareAgent)
    end
  end

  # NOTE: revisit per task 0053 — `as: :middleware` override on a non-middleware
  # module no longer applies with the unambiguous `middleware: [...]` channel.
  # The mismatch error path will surface via different validation.
  describe "task 0034 enforcement: as: :middleware mismatch" do
    @describetag :skip
    test "as: :middleware on a non-middleware module raises" do
      assert_raise RuntimeError, ~r/does not implement Jido.Middleware/, fn ->
        defmodule NonMiddlewareSlice do
          @moduledoc false
          use Jido.Slice

          slice do
            name "non_middleware"
            path :non_middleware
            schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
          end

          signal_routes do
            route "non_middleware.noop", JidoTest.PluginTestAction
          end
        end

        defmodule BadMiddlewareAgent do
          use Jido.Agent,
            extensions: [{Jido.Dsl.MiddlewareTest.NonMiddlewareSlice, [as: :middleware]}]

          agent do
            name "bad_middleware_agent"
          end
        end
      end
    end
  end
end
