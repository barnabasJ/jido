defmodule Jido.Dsl.AgentKindInferenceTest do
  use ExUnit.Case, async: true

  # Cover kind inference from markers (`__jido_plugin__/0`,
  # `__jido_slice__/0`, `Jido.Middleware` behaviour), the rare
  # `{Mod, as: :slice}` override, and marker-mismatch errors.

  Code.ensure_compiled!(JidoTest.PluginTestAction)

  defmodule SamplePlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "sample_plugin",
      path: :sample_plugin,
      actions: [JidoTest.PluginTestAction]
  end

  defmodule SampleSlice do
    @moduledoc false
    use Jido.Slice,
      name: "sample_slice",
      path: :sample_slice,
      actions: []
  end

  defmodule SampleMiddleware do
    @moduledoc false
    use Jido.Middleware

    @impl true
    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  describe "kind inference from markers" do
    defmodule PluginAgent do
      @moduledoc false
      use Jido.Agent, extensions: [Jido.Dsl.AgentKindInferenceTest.SamplePlugin]

      agent do
        name "plugin_agent"
        path :domain
      end
    end

    test "plugin marker → :plugin (appears in plugins/0, not slices/0 or middleware/0)" do
      assert SamplePlugin in PluginAgent.plugins()
      refute SamplePlugin in PluginAgent.slices()
      refute Enum.any?(PluginAgent.middleware(), &match?({SamplePlugin, _}, &1))
    end

    defmodule SliceAgent do
      @moduledoc false
      use Jido.Agent, extensions: [Jido.Dsl.AgentKindInferenceTest.SampleSlice]

      agent do
        name "slice_agent"
        path :domain
      end
    end

    test "slice marker → :slice (appears in slices/0, not plugins/0 or middleware/0)" do
      assert SampleSlice in SliceAgent.slices()
      refute SampleSlice in SliceAgent.plugins()
      refute Enum.any?(SliceAgent.middleware(), &match?({SampleSlice, _}, &1))
    end

    defmodule MiddlewareAgent do
      @moduledoc false
      use Jido.Agent, extensions: [Jido.Dsl.AgentKindInferenceTest.SampleMiddleware]

      agent do
        name "middleware_agent"
        path :domain
      end
    end

    test "Jido.Middleware behaviour → :middleware (appears in middleware/0, not plugins or slices)" do
      assert Enum.any?(MiddlewareAgent.middleware(), &match?({SampleMiddleware, _}, &1))
      refute SampleMiddleware in MiddlewareAgent.plugins()
      refute SampleMiddleware in MiddlewareAgent.slices()
    end
  end

  describe "kind override (rare): `{Mod, as: :slice}`" do
    defmodule OverridePluginToSliceAgent do
      @moduledoc false
      use Jido.Agent,
        extensions: [{Jido.Dsl.AgentKindInferenceTest.SamplePlugin, [as: :slice]}]

      agent do
        name "override_to_slice_agent"
        path :domain
      end
    end

    test "force-mounts a plugin as a slice via `as: :slice`" do
      assert SamplePlugin in OverridePluginToSliceAgent.slices()
      refute SamplePlugin in OverridePluginToSliceAgent.plugins()
    end
  end

  describe "marker-mismatch errors" do
    test "`as: :plugin` on a bare slice raises at compile time" do
      assert_raise RuntimeError, ~r/missing __jido_plugin__/, fn ->
        defmodule BadOverride do
          use Jido.Agent,
            extensions: [{Jido.Dsl.AgentKindInferenceTest.SampleSlice, [as: :plugin]}]

          agent do
            name "bad_override"
            path :domain
          end
        end
      end
    end

    test "`as: :middleware` on a non-middleware module raises at compile time" do
      # `Jido.Plugin` mixes in `use Jido.Middleware`, so plugins ARE middlewares
      # for kind inference. A bare `use Jido.Slice` module is not, so this is
      # the right shape for an `as: :middleware` mismatch.
      assert_raise RuntimeError, ~r/does not implement Jido.Middleware/, fn ->
        defmodule BadMiddlewareOverride do
          use Jido.Agent,
            extensions: [{Jido.Dsl.AgentKindInferenceTest.SampleSlice, [as: :middleware]}]

          agent do
            name "bad_middleware_override"
            path :domain
          end
        end
      end
    end

    test "module with no markers raises at compile time" do
      defmodule NoMarkers do
        def some_function, do: :ok
      end

      assert_raise RuntimeError,
                   ~r/is not a Jido.Plugin, Jido.Slice, or Jido.Middleware/,
                   fn ->
                     defmodule BadAgent do
                       use Jido.Agent,
                         extensions: [Jido.Dsl.AgentKindInferenceTest.NoMarkers]

                       agent do
                         name "bad_agent"
                         path :domain
                       end
                     end
                   end
    end
  end

  describe "defoverridable parity" do
    defmodule OverridableAgent do
      @moduledoc false
      use Jido.Agent

      agent do
        name "overridable_agent"
        path :domain
      end

      def signal_routes, do: [{"override.fired", JidoTest.PluginTestAction}]
    end

    test "user override of signal_routes/0 wins" do
      assert OverridableAgent.signal_routes() == [
               {"override.fired", JidoTest.PluginTestAction}
             ]
    end
  end
end
