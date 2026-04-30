defmodule JidoTest.Plugin.InstanceTest do
  use ExUnit.Case, async: true

  alias Jido.Plugin.Instance

  defmodule TestPlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "test_plugin"
      schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
    end
  end

  defmodule SlackPlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "slack"
      schema Zoi.object(%{token: Zoi.string() |> Zoi.optional()})
    end
  end

  describe "new/1" do
    test "creates instance from module alone" do
      instance = Instance.new(TestPlugin, :test)

      assert instance.module == TestPlugin
      assert instance.as == nil
      assert instance.config == %{}
      assert instance.path == :test
      assert instance.route_prefix == "test_plugin"
      assert Jido.Dsl.Plugin.Info.name(instance.module) == "test_plugin"
    end

    test "creates instance from {module, map} tuple" do
      instance = Instance.new({TestPlugin, %{custom: "value"}}, :test)

      assert instance.module == TestPlugin
      assert instance.as == nil
      assert instance.config == %{custom: "value"}
      assert instance.path == :test
      assert instance.route_prefix == "test_plugin"
    end

    test "creates instance from {module, keyword_list} without :as" do
      instance = Instance.new({TestPlugin, [custom: "value", other: 123]}, :test)

      assert instance.module == TestPlugin
      assert instance.as == nil
      assert instance.config == %{custom: "value", other: 123}
      assert instance.path == :test
      assert instance.route_prefix == "test_plugin"
    end

    test "creates instance with :as option from keyword list" do
      instance = Instance.new({SlackPlugin, as: :support, token: "support-token"}, :slack)

      assert instance.module == SlackPlugin
      assert instance.as == :support
      assert instance.config == %{token: "support-token"}
      assert instance.path == :slack_support
      assert instance.route_prefix == "support.slack"
    end

    test "creates instance with only :as option" do
      instance = Instance.new({SlackPlugin, as: :sales}, :slack)

      assert instance.module == SlackPlugin
      assert instance.as == :sales
      assert instance.config == %{}
      assert instance.path == :slack_sales
      assert instance.route_prefix == "sales.slack"
    end

    test "Info accessors read directly from the plugin module" do
      instance = Instance.new(TestPlugin, :test)

      assert instance.module == TestPlugin
      assert Jido.Dsl.Plugin.Info.name(instance.module) == "test_plugin"
    end
  end

  describe "derive_path/2" do
    test "returns base key when as is nil" do
      assert Instance.derive_path(:slack, nil) == :slack
      assert Instance.derive_path(:database, nil) == :database
    end

    test "appends alias to base key" do
      assert Instance.derive_path(:slack, :support) == :slack_support
      assert Instance.derive_path(:slack, :sales) == :slack_sales
      assert Instance.derive_path(:database, :primary) == :database_primary
    end
  end

  describe "derive_route_prefix/2" do
    test "returns base name when as is nil" do
      assert Instance.derive_route_prefix("slack", nil) == "slack"
      assert Instance.derive_route_prefix("database", nil) == "database"
    end

    test "prefixes with alias" do
      assert Instance.derive_route_prefix("slack", :support) == "support.slack"
      assert Instance.derive_route_prefix("slack", :sales) == "sales.slack"
      assert Instance.derive_route_prefix("database", :primary) == "primary.database"
    end
  end

  describe "multiple instances of same plugin" do
    test "same plugin with different :as values get different state keys" do
      support_instance = Instance.new({SlackPlugin, as: :support}, :slack)
      sales_instance = Instance.new({SlackPlugin, as: :sales}, :slack)
      default_instance = Instance.new(SlackPlugin, :slack)

      assert support_instance.path == :slack_support
      assert sales_instance.path == :slack_sales
      assert default_instance.path == :slack

      assert support_instance.path != sales_instance.path
      assert support_instance.path != default_instance.path
      assert sales_instance.path != default_instance.path
    end

    test "same plugin with different :as values get different route prefixes" do
      support_instance = Instance.new({SlackPlugin, as: :support}, :slack)
      sales_instance = Instance.new({SlackPlugin, as: :sales}, :slack)
      default_instance = Instance.new(SlackPlugin, :slack)

      assert support_instance.route_prefix == "support.slack"
      assert sales_instance.route_prefix == "sales.slack"
      assert default_instance.route_prefix == "slack"
    end

    test "different configs are preserved per instance" do
      support_instance = Instance.new({SlackPlugin, as: :support, token: "support-token"}, :slack)
      sales_instance = Instance.new({SlackPlugin, as: :sales, token: "sales-token"}, :slack)

      assert support_instance.config == %{token: "support-token"}
      assert sales_instance.config == %{token: "sales-token"}
    end
  end

  describe "alias mechanics" do
    test "plugin can be aliased with as:" do
      instance = Instance.new({SlackPlugin, as: :support}, :slack)
      assert instance.as == :support
      assert instance.path == :slack_support
    end
  end
end
