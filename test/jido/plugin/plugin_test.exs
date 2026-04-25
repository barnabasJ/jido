defmodule JidoTest.PluginTest do
  use ExUnit.Case, async: true

  alias Jido.Plugin.Manifest
  alias Jido.Plugin.Spec

  defmodule BasicPlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "basic_plugin",
      path: :basic,
      actions: [JidoTest.PluginTestAction]
  end

  defmodule FullPlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "full_plugin",
      path: :full,
      actions: [JidoTest.PluginTestAction, JidoTest.PluginTestAnotherAction],
      description: "A fully configured plugin",
      category: "test",
      vsn: "1.0.0",
      schema: Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)}),
      config_schema: Zoi.object(%{enabled: Zoi.boolean() |> Zoi.default(true)}),
      tags: ["test", "full"],
      capabilities: [:messaging, :notifications],
      requires: [{:config, :api_key}, {:app, :req}],
      signal_routes: [
        {"post", JidoTest.PluginTestAction},
        {"get", JidoTest.PluginTestAnotherAction}
      ],
      schedules: [{"*/5 * * * *", JidoTest.PluginTestAction}]
  end

  defmodule SingletonPlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "singleton_plugin",
      path: :singleton_state,
      actions: [JidoTest.PluginTestAction],
      singleton: true
  end

  describe "plugin definition with required fields" do
    test "defines a basic plugin with required fields" do
      assert BasicPlugin.name() == "basic_plugin"
      assert BasicPlugin.path() == :basic
      assert BasicPlugin.actions() == [JidoTest.PluginTestAction]
    end

    test "optional fields default to nil or empty" do
      assert BasicPlugin.description() == nil
      assert BasicPlugin.category() == nil
      assert BasicPlugin.vsn() == nil
      assert BasicPlugin.schema() == nil
      assert BasicPlugin.config_schema() == nil
      assert BasicPlugin.tags() == []
      assert BasicPlugin.capabilities() == []
      assert BasicPlugin.requires() == []
      assert BasicPlugin.signal_routes() == []
      assert BasicPlugin.schedules() == []
    end
  end

  describe "plugin definition with all optional fields" do
    test "defines a plugin with all optional fields" do
      assert FullPlugin.name() == "full_plugin"
      assert FullPlugin.path() == :full
      assert FullPlugin.actions() == [JidoTest.PluginTestAction, JidoTest.PluginTestAnotherAction]
      assert FullPlugin.description() == "A fully configured plugin"
      assert FullPlugin.category() == "test"
      assert FullPlugin.vsn() == "1.0.0"
      assert FullPlugin.schema() != nil
      assert FullPlugin.config_schema() != nil
      assert FullPlugin.tags() == ["test", "full"]
      assert FullPlugin.capabilities() == [:messaging, :notifications]
      assert FullPlugin.requires() == [{:config, :api_key}, {:app, :req}]

      assert FullPlugin.signal_routes() == [
               {"post", JidoTest.PluginTestAction},
               {"get", JidoTest.PluginTestAnotherAction}
             ]

      assert FullPlugin.schedules() == [{"*/5 * * * *", JidoTest.PluginTestAction}]
    end
  end

  describe "plugin_spec/0 and plugin_spec/1" do
    test "plugin_spec/0 returns correct Spec struct with defaults" do
      spec = BasicPlugin.plugin_spec()

      assert %Spec{} = spec
      assert spec.module == BasicPlugin
      assert spec.name == "basic_plugin"
      assert spec.path == :basic
      assert spec.actions == [JidoTest.PluginTestAction]
      assert spec.config == %{}
      assert spec.description == nil
      assert spec.category == nil
      assert spec.vsn == nil
      assert spec.schema == nil
      assert spec.config_schema == nil
      assert spec.tags == []
    end

    test "plugin_spec/0 returns correct Spec struct with all fields" do
      spec = FullPlugin.plugin_spec()

      assert %Spec{} = spec
      assert spec.module == FullPlugin
      assert spec.name == "full_plugin"
      assert spec.path == :full
      assert spec.actions == [JidoTest.PluginTestAction, JidoTest.PluginTestAnotherAction]
      assert spec.description == "A fully configured plugin"
      assert spec.category == "test"
      assert spec.vsn == "1.0.0"
      assert spec.schema != nil
      assert spec.config_schema != nil
      assert spec.tags == ["test", "full"]
    end

    test "plugin_spec/1 accepts config overrides" do
      spec = BasicPlugin.plugin_spec(%{custom_option: true, setting: "value"})

      assert spec.config == %{custom_option: true, setting: "value"}
    end

    test "plugin_spec/1 with empty config returns empty map" do
      spec = BasicPlugin.plugin_spec(%{})
      assert spec.config == %{}
    end
  end

  describe "metadata accessors" do
    @metadata_cases [
      # {function, BasicPlugin expected, FullPlugin expected}
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

      test "#{@fun}/0 returns correct value for BasicPlugin and FullPlugin" do
        assert apply(BasicPlugin, @fun, []) == @basic_expected
        assert apply(FullPlugin, @fun, []) == @full_expected
      end
    end

    test "schema/0 returns nil for BasicPlugin and Zoi schema for FullPlugin" do
      assert BasicPlugin.schema() == nil
      assert FullPlugin.schema() != nil
    end

    test "config_schema/0 returns nil for BasicPlugin and Zoi schema for FullPlugin" do
      assert BasicPlugin.config_schema() == nil
      assert FullPlugin.config_schema() != nil
    end
  end

  describe "compile-time validation" do
    test "missing required field raises CompileError" do
      assert_raise CompileError, fn ->
        defmodule MissingNamePlugin do
          use Jido.Plugin,
            path: :missing,
            actions: [JidoTest.PluginTestAction]
        end
      end
    end

    test "missing path raises CompileError" do
      assert_raise CompileError, fn ->
        defmodule MissingPathPlugin do
          use Jido.Plugin,
            name: "missing_path",
            actions: [JidoTest.PluginTestAction]
        end
      end
    end

    test "invalid action module raises CompileError" do
      assert_raise CompileError, fn ->
        defmodule InvalidActionPlugin do
          use Jido.Plugin,
            name: "invalid_action",
            path: :invalid,
            actions: [NonExistentModule]
        end
      end
    end

    test "module that doesn't implement Action behavior raises CompileError" do
      assert_raise CompileError, fn ->
        defmodule NotActionPlugin do
          use Jido.Plugin,
            name: "not_action",
            path: :not_action,
            actions: [JidoTest.NotAnActionModule]
        end
      end
    end

    test "invalid name format raises CompileError" do
      assert_raise CompileError, fn ->
        defmodule InvalidNamePlugin do
          use Jido.Plugin,
            name: "invalid-name-with-dashes",
            path: :invalid,
            actions: [JidoTest.PluginTestAction]
        end
      end
    end
  end

  describe "manifest/0" do
    test "returns correct Manifest struct for BasicPlugin" do
      manifest = BasicPlugin.manifest()

      assert %Manifest{} = manifest
      assert manifest.module == BasicPlugin
      assert manifest.name == "basic_plugin"
      assert manifest.path == :basic
      assert manifest.actions == [JidoTest.PluginTestAction]
      assert manifest.description == nil
      assert manifest.category == nil
      assert manifest.vsn == nil
      assert manifest.schema == nil
      assert manifest.config_schema == nil
      assert manifest.tags == []
      assert manifest.capabilities == []
      assert manifest.requires == []
      assert manifest.signal_routes == []
      assert manifest.schedules == []
    end

    test "returns correct Manifest struct for FullPlugin" do
      manifest = FullPlugin.manifest()

      assert %Manifest{} = manifest
      assert manifest.module == FullPlugin
      assert manifest.name == "full_plugin"
      assert manifest.path == :full
      assert manifest.actions == [JidoTest.PluginTestAction, JidoTest.PluginTestAnotherAction]
      assert manifest.description == "A fully configured plugin"
      assert manifest.category == "test"
      assert manifest.vsn == "1.0.0"
      assert manifest.schema != nil
      assert manifest.config_schema != nil
      assert manifest.tags == ["test", "full"]
      assert manifest.capabilities == [:messaging, :notifications]
      assert manifest.requires == [{:config, :api_key}, {:app, :req}]

      assert manifest.signal_routes == [
               {"post", JidoTest.PluginTestAction},
               {"get", JidoTest.PluginTestAnotherAction}
             ]

      assert manifest.schedules == [{"*/5 * * * *", JidoTest.PluginTestAction}]
    end
  end

  describe "__plugin_metadata__/0" do
    test "returns correct metadata map for BasicPlugin" do
      metadata = BasicPlugin.__plugin_metadata__()

      assert metadata == %{
               name: "basic_plugin",
               description: nil,
               category: nil,
               tags: []
             }
    end

    test "returns correct metadata map for FullPlugin" do
      metadata = FullPlugin.__plugin_metadata__()

      assert metadata == %{
               name: "full_plugin",
               description: "A fully configured plugin",
               category: "test",
               tags: ["test", "full"]
             }
    end

    test "metadata is compatible with Jido.Discovery expectations" do
      metadata = FullPlugin.__plugin_metadata__()

      assert is_binary(metadata.name)
      assert is_binary(metadata.description) or is_nil(metadata.description)
      assert is_binary(metadata.category) or is_nil(metadata.category)
      assert is_list(metadata.tags)
    end
  end

  describe "accessor functions" do
    test "capabilities/0 returns correct values" do
      assert BasicPlugin.capabilities() == []
      assert FullPlugin.capabilities() == [:messaging, :notifications]
    end

    test "requires/0 returns correct values" do
      assert BasicPlugin.requires() == []
      assert FullPlugin.requires() == [{:config, :api_key}, {:app, :req}]
    end

    test "signal_routes/0 returns correct values" do
      assert BasicPlugin.signal_routes() == []

      assert FullPlugin.signal_routes() == [
               {"post", JidoTest.PluginTestAction},
               {"get", JidoTest.PluginTestAnotherAction}
             ]
    end

    test "schedules/0 returns correct values" do
      assert BasicPlugin.schedules() == []
      assert FullPlugin.schedules() == [{"*/5 * * * *", JidoTest.PluginTestAction}]
    end
  end

  describe "singleton option" do
    test "singleton defaults to false for regular plugins" do
      refute BasicPlugin.singleton?()
      refute FullPlugin.singleton?()
    end

    test "singleton? returns true when configured" do
      assert SingletonPlugin.singleton?()
    end

    test "singleton is included in manifest" do
      assert SingletonPlugin.manifest().singleton == true
      assert BasicPlugin.manifest().singleton == false
    end
  end
end
