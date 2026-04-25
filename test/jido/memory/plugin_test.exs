defmodule JidoTest.Memory.PluginTest do
  use ExUnit.Case, async: true

  alias Jido.Memory
  alias Jido.Memory.Plugin, as: MemoryPlugin

  describe "plugin metadata" do
    test "name is memory" do
      assert MemoryPlugin.name() == "memory"
    end

    test "path is :memory" do
      assert MemoryPlugin.path() == :memory
    end

    test "is singleton" do
      assert MemoryPlugin.singleton?() == true
    end

    test "has memory capability" do
      assert :memory in MemoryPlugin.capabilities()
    end

    test "has no actions" do
      assert MemoryPlugin.actions() == []
    end

    test "schema is nil (no auto-initialization)" do
      assert MemoryPlugin.schema() == nil
    end
  end

  describe "manifest" do
    test "singleton is true in manifest" do
      manifest = MemoryPlugin.manifest()
      assert manifest.singleton == true
    end

    test "path is :memory in manifest" do
      manifest = MemoryPlugin.manifest()
      assert manifest.path == :memory
    end
  end

  describe "agent integration" do
    defmodule AgentWithMemory do
      use Jido.Agent, name: "memory_plugin_test_agent", path: :domain
    end

    defmodule AgentWithoutMemory do
      use Jido.Agent,
        name: "memory_plugin_test_no_memory",
        path: :domain,
        default_plugins: %{memory: false}
    end

    test "agent includes memory plugin by default" do
      modules = AgentWithMemory.plugins()
      assert Jido.Memory.Plugin in modules
    end

    test "agent can disable memory plugin" do
      modules = AgentWithoutMemory.plugins()
      refute Jido.Memory.Plugin in modules
    end

    test "memory can be attached after creation via Memory.Agent" do
      agent = AgentWithMemory.new()
      agent = Memory.Agent.ensure(agent)
      assert %Memory{} = Memory.Agent.get(agent)
    end

    test "cannot alias memory plugin" do
      assert_raise ArgumentError, ~r/Cannot alias singleton plugin/, fn ->
        Jido.Plugin.Instance.new({Jido.Memory.Plugin, as: :my_memory})
      end
    end
  end
end
