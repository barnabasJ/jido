defmodule JidoTest.Plugin.SingletonCompileTest do
  use ExUnit.Case, async: true

  defmodule SingletonFixture do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "singleton_fixture"
      path :singleton_fix
      singleton true
    end

    actions do
      action JidoTest.PluginTestAction
    end
  end

  defmodule RegularFixture do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "regular_fixture"
      path :regular_fix
    end

    actions do
      action JidoTest.PluginTestAction
    end
  end

  describe "compile-time singleton enforcement" do
    test "agent with singleton plugin compiles successfully" do
      defmodule ValidSingletonAgent do
        use Jido.Agent,
          extensions: [SingletonFixture],
          default_slices: false

        agent do
          name "valid_singleton"
          path :domain
        end
      end

      assert ValidSingletonAgent.plugins() |> length() == 1
    end

    test "agent with singleton and regular plugins compiles" do
      defmodule MixedPluginAgent do
        use Jido.Agent,
          extensions: [SingletonFixture, RegularFixture],
          default_slices: false

        agent do
          name "mixed_plugins"
          path :domain
        end
      end

      assert MixedPluginAgent.plugins() |> length() == 2
    end

    test "agent raises when singleton plugin is aliased" do
      assert_raise RuntimeError, ~r/Cannot alias singleton plugin/, fn ->
        defmodule AliasedSingletonAgent do
          use Jido.Agent,
            extensions: [{SingletonFixture, [as: :custom]}]

          agent do
            name "aliased_singleton"
            path :domain
          end
        end
      end
    end

    test "agent emits a warning when singleton plugin is duplicated" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule DuplicateSingletonAgent do
            use Jido.Agent,
              extensions: [SingletonFixture, SingletonFixture]

            agent do
              name "duplicate_singleton"
              path :domain
            end
          end
        end)

      assert stderr =~ ~r/[Dd]uplicate.*singleton/
    end

    test "regular (non-singleton) plugin can still be aliased" do
      defmodule AliasedRegularAgent do
        use Jido.Agent,
          extensions: [{RegularFixture, [as: :alias1]}],
          default_slices: false

        agent do
          name "aliased_regular"
          path :domain
        end
      end

      instances = AliasedRegularAgent.plugin_instances()
      assert length(instances) == 1
      assert hd(instances).as == :alias1
    end
  end
end
