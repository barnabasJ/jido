defmodule Jido.Dsl.AgentKindInferenceTest do
  use ExUnit.Case, async: true

  # NOTE: revisit per task 0053 — kind inference from markers in a single
  # `extensions: [...]` flat list no longer applies. The new surface uses
  # explicit `slices do …` / `middleware: […]` / `extensions: […]` sections,
  # so kind classification is unambiguous by construction. Tests in this
  # file exercise the obsolete classification semantics and are skipped
  # until they're either rewritten for the new surface or removed.
  @moduletag :skip

  # Cover kind inference from Spark host identity
  # (`Spark.Dsl.is?(mod, Jido.Plugin)`,
  # `Spark.Dsl.is?(mod, Jido.Slice)`, `Jido.Middleware` behaviour),
  # the rare `{Mod, as: :slice}` override, and marker-mismatch errors.

  Code.ensure_compiled!(JidoTest.PluginTestAction)

  defmodule SamplePlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "sample_plugin"
      path :sample_plugin
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "sample_plugin.noop", JidoTest.PluginTestAction
    end
  end

  defmodule SampleSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "sample_slice"
      path :sample_slice
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "sample_slice.noop", JidoTest.PluginTestAction
    end
  end

  defmodule SampleMiddleware do
    @moduledoc false
    use Jido.Middleware

    @impl true
    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  # NOTE: revisit per task 0053 — kind inference from a flat `extensions: […]`
  # list is no longer the entry point. Slice/plugin/middleware kinds are
  # disambiguated by which DSL section/option each entry lives in:
  #   - `slices do …`            → slices
  #   - `middleware: […]`        → middleware
  #   - `extensions: […]`        → DSL-contributing modules
  # The tests below convert the registration to the new surface but the
  # underlying premise (inferring kind from a single list) is obsolete.
  describe "kind inference from markers" do
    defmodule PluginAgent do
      @moduledoc false
      use Jido.Agent,
        middleware: [Jido.Dsl.AgentKindInferenceTest.SamplePlugin]

      agent do
        name "plugin_agent"
      end

      slices do
        slice(:sample_plugin, Jido.Dsl.AgentKindInferenceTest.SamplePlugin)
      end
    end

    test "plugin marker → :plugin (appears in plugins/0, not slices/0 or middleware/0)" do
      assert SamplePlugin in Jido.Dsl.Agent.Info.plugins(PluginAgent)
      refute SamplePlugin in Jido.Dsl.Agent.Info.slices(PluginAgent)

      refute Enum.any?(
               Jido.Dsl.Agent.Info.middleware(PluginAgent),
               &match?({SamplePlugin, _}, &1)
             )
    end

    defmodule SliceAgent do
      @moduledoc false
      use Jido.Agent

      agent do
        name "slice_agent"
      end

      slices do
        slice(:sample_slice, Jido.Dsl.AgentKindInferenceTest.SampleSlice)
      end
    end

    test "slice marker → :slice (appears in slices/0, not plugins/0 or middleware/0)" do
      assert SampleSlice in Jido.Dsl.Agent.Info.slices(SliceAgent)
      refute SampleSlice in Jido.Dsl.Agent.Info.plugins(SliceAgent)
      refute Enum.any?(Jido.Dsl.Agent.Info.middleware(SliceAgent), &match?({SampleSlice, _}, &1))
    end

    defmodule MiddlewareAgent do
      @moduledoc false
      use Jido.Agent,
        middleware: [Jido.Dsl.AgentKindInferenceTest.SampleMiddleware]

      agent do
        name "middleware_agent"
      end
    end

    test "Jido.Middleware behaviour → :middleware (appears in middleware/0, not plugins or slices)" do
      assert Enum.any?(
               Jido.Dsl.Agent.Info.middleware(MiddlewareAgent),
               &match?({SampleMiddleware, _}, &1)
             )

      refute SampleMiddleware in Jido.Dsl.Agent.Info.plugins(MiddlewareAgent)
      refute SampleMiddleware in Jido.Dsl.Agent.Info.slices(MiddlewareAgent)
    end
  end

  # NOTE: revisit per task 0053 — `as:` overrides and force-classification
  # semantics likely no longer apply with the new unambiguous DSL surface.
  describe "kind override (rare): `{Mod, as: :slice}`" do
    defmodule OverridePluginToSliceAgent do
      @moduledoc false
      use Jido.Agent,
        extensions: [{Jido.Dsl.AgentKindInferenceTest.SamplePlugin, [as: :slice]}]

      agent do
        name "override_to_slice_agent"
      end
    end

    test "force-mounts a plugin as a slice via `as: :slice`" do
      assert SamplePlugin in Jido.Dsl.Agent.Info.slices(OverridePluginToSliceAgent)
      refute SamplePlugin in Jido.Dsl.Agent.Info.plugins(OverridePluginToSliceAgent)
    end
  end

  # NOTE: revisit per task 0053 — marker-mismatch errors arose from inferring
  # kind from `extensions: […]`. With distinct DSL sections, the error shape
  # and trigger conditions change.
  describe "marker-mismatch errors" do
    test "`as: :plugin` on a bare slice raises at compile time" do
      assert_raise RuntimeError, ~r/is not a `use Jido.Plugin` module/, fn ->
        defmodule BadOverride do
          use Jido.Agent,
            extensions: [{Jido.Dsl.AgentKindInferenceTest.SampleSlice, [as: :plugin]}]

          agent do
            name "bad_override"
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
                       end
                     end
                   end
    end
  end

  describe "signal_routes section" do
    defmodule SectionedRoutesAgent do
      @moduledoc false
      use Jido.Agent

      agent do
        name "sectioned_routes_agent"
      end

      signal_routes do
        route "section.fired", JidoTest.PluginTestAction
      end
    end

    test "section-declared routes are surfaced via Agent.Info.signal_routes/1" do
      assert Jido.Dsl.Agent.Info.signal_routes(SectionedRoutesAgent) == [
               {"section.fired", JidoTest.PluginTestAction}
             ]
    end
  end
end
