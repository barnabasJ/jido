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

    test "neither slice nor plugin marker is emitted on a bare middleware" do
      refute function_exported?(MinimalMiddleware, :__jido_slice__, 0)
      refute function_exported?(MinimalMiddleware, :__jido_plugin__, 0)
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
        extensions: [Jido.Dsl.MiddlewareTest.MinimalMiddleware],
        default_slices: false

      agent do
        name "middleware_agent"
      end
    end

    test "middleware appears in middleware/0, not plugins/0 or slices/0" do
      assert Enum.any?(MiddlewareAgent.middleware(), &match?({MinimalMiddleware, _}, &1))
      refute MinimalMiddleware in MiddlewareAgent.plugins()
      refute MinimalMiddleware in MiddlewareAgent.slices()
    end
  end

  describe "task 0034 enforcement: as: :middleware mismatch" do
    test "as: :middleware on a non-middleware module raises" do
      assert_raise RuntimeError, ~r/does not implement Jido.Middleware/, fn ->
        defmodule NonMiddlewareSlice do
          @moduledoc false
          use Jido.Slice

          slice do
            name "non_middleware"
            path :non_middleware
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
