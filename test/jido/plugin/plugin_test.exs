defmodule JidoTest.PluginTest do
  use ExUnit.Case, async: true

  alias Jido.Dsl.Plugin.Info, as: PluginInfo

  defmodule BasicPlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "basic_plugin"
      path :basic
    end

    signal_routes do
      route "basic.do", JidoTest.PluginTestAction
    end
  end

  defmodule FullPlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "full_plugin"
      path :full
      description "A fully configured plugin"
      category "test"
      vsn "1.0.0"
      schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
      config_schema Zoi.object(%{enabled: Zoi.boolean() |> Zoi.default(true)})
      tags ["test", "full"]
    end

    capabilities do
      capability :messaging
      capability :notifications
    end

    requires do
      requires :config, :api_key
      requires :app, :req
    end

    signal_routes do
      route "post", JidoTest.PluginTestAction
      route "get", JidoTest.PluginTestAnotherAction
    end

    schedules do
      schedule "*/5 * * * *", JidoTest.PluginTestAction
    end
  end

  describe "plugin definition with required fields" do
    test "defines a basic plugin with required fields" do
      assert PluginInfo.name(BasicPlugin) == "basic_plugin"
      assert PluginInfo.path(BasicPlugin) == :basic
      assert PluginInfo.actions(BasicPlugin) == [JidoTest.PluginTestAction]
    end

    test "optional fields default to nil or empty" do
      assert PluginInfo.description(BasicPlugin) == nil
      assert PluginInfo.category(BasicPlugin) == nil
      assert PluginInfo.vsn(BasicPlugin) == nil
      assert PluginInfo.schema(BasicPlugin) == nil
      assert PluginInfo.config_schema(BasicPlugin) == nil
      assert PluginInfo.tags(BasicPlugin) == []
      assert PluginInfo.capabilities(BasicPlugin) == []
      assert PluginInfo.requires(BasicPlugin) == []
      assert PluginInfo.schedules(BasicPlugin) == []
    end
  end

  describe "plugin definition with all optional fields" do
    test "defines a plugin with all optional fields" do
      assert PluginInfo.name(FullPlugin) == "full_plugin"
      assert PluginInfo.path(FullPlugin) == :full

      assert PluginInfo.actions(FullPlugin) == [
               JidoTest.PluginTestAction,
               JidoTest.PluginTestAnotherAction
             ]

      assert PluginInfo.description(FullPlugin) == "A fully configured plugin"
      assert PluginInfo.category(FullPlugin) == "test"
      assert PluginInfo.vsn(FullPlugin) == "1.0.0"
      assert PluginInfo.schema(FullPlugin) != nil
      assert PluginInfo.config_schema(FullPlugin) != nil
      assert PluginInfo.tags(FullPlugin) == ["test", "full"]
      assert PluginInfo.capabilities(FullPlugin) == [:messaging, :notifications]
      assert PluginInfo.requires(FullPlugin) == [{:config, :api_key}, {:app, :req}]

      assert PluginInfo.signal_routes(FullPlugin) == [
               {"post", JidoTest.PluginTestAction},
               {"get", JidoTest.PluginTestAnotherAction}
             ]

      assert PluginInfo.schedules(FullPlugin) == [{"*/5 * * * *", JidoTest.PluginTestAction}]
    end
  end

  describe "metadata accessors" do
    @metadata_cases [
      # {accessor_name, BasicPlugin expected, FullPlugin expected}
      {:name, "basic_plugin", "full_plugin"},
      {:path, :basic, :full},
      {:description, nil, "A fully configured plugin"},
      {:category, nil, "test"},
      {:vsn, nil, "1.0.0"},
      {:tags, [], ["test", "full"]},
      {:actions, [JidoTest.PluginTestAction],
       [JidoTest.PluginTestAction, JidoTest.PluginTestAnotherAction]}
    ]

    for {fun, basic_expected, full_expected} <- @metadata_cases do
      @fun fun
      @basic_expected basic_expected
      @full_expected full_expected

      test "Info.#{@fun}/1 returns correct value for BasicPlugin and FullPlugin" do
        assert apply(PluginInfo, @fun, [BasicPlugin]) == @basic_expected
        assert apply(PluginInfo, @fun, [FullPlugin]) == @full_expected
      end
    end

    test "schema/1 returns nil for BasicPlugin and Zoi schema for FullPlugin" do
      assert PluginInfo.schema(BasicPlugin) == nil
      assert PluginInfo.schema(FullPlugin) != nil
    end

    test "config_schema/1 returns nil for BasicPlugin and Zoi schema for FullPlugin" do
      assert PluginInfo.config_schema(BasicPlugin) == nil
      assert PluginInfo.config_schema(FullPlugin) != nil
    end
  end

  describe "compile-time validation" do
    test "missing required field raises" do
      assert_raise Spark.Error.DslError, fn ->
        defmodule MissingNamePlugin do
          use Jido.Plugin

          slice do
            path :missing
          end
        end
      end
    end

    test "missing path raises" do
      assert_raise Spark.Error.DslError, fn ->
        defmodule MissingPathPlugin do
          use Jido.Plugin

          slice do
            name "missing_path"
          end
        end
      end
    end

    test "invalid name format raises" do
      assert_raise Spark.Error.DslError, fn ->
        defmodule InvalidNamePlugin do
          use Jido.Plugin

          slice do
            name "invalid-name-with-dashes"
            path :invalid
          end
        end
      end
    end
  end

  describe "accessor functions" do
    test "capabilities/1 returns correct values" do
      assert PluginInfo.capabilities(BasicPlugin) == []
      assert PluginInfo.capabilities(FullPlugin) == [:messaging, :notifications]
    end

    test "requires/1 returns correct values" do
      assert PluginInfo.requires(BasicPlugin) == []
      assert PluginInfo.requires(FullPlugin) == [{:config, :api_key}, {:app, :req}]
    end

    test "signal_routes/1 returns correct values" do
      assert PluginInfo.signal_routes(BasicPlugin) == [{"basic.do", JidoTest.PluginTestAction}]

      assert PluginInfo.signal_routes(FullPlugin) == [
               {"post", JidoTest.PluginTestAction},
               {"get", JidoTest.PluginTestAnotherAction}
             ]
    end

    test "schedules/1 returns correct values" do
      assert PluginInfo.schedules(BasicPlugin) == []
      assert PluginInfo.schedules(FullPlugin) == [{"*/5 * * * *", JidoTest.PluginTestAction}]
    end
  end
end
