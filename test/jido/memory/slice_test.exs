defmodule JidoTest.Memory.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Memory
  alias Jido.Memory.Slice, as: MemorySlice

  describe "slice metadata" do
    test "name is memory" do
      assert MemorySlice.name() == "memory"
    end

    test "path is :memory" do
      assert MemorySlice.path() == :memory
    end

    test "has memory capability" do
      assert :memory in MemorySlice.capabilities()
    end

    test "has no actions" do
      assert MemorySlice.actions() == []
    end

    test "schema is nil (no auto-initialization)" do
      assert MemorySlice.schema() == nil
    end
  end

  describe "manifest" do
    test "path is :memory in manifest" do
      manifest = MemorySlice.manifest()
      assert manifest.path == :memory
    end
  end

  describe "agent integration" do
    defmodule AgentWithMemory do
      use Jido.Agent

      agent do
        name "memory_slice_test_agent"
        path :domain
      end
    end

    defmodule AgentWithoutMemory do
      use Jido.Agent,
        default_slices: %{memory: false}

      agent do
        name "memory_slice_test_no_memory"
        path :domain
      end
    end

    test "agent includes memory slice by default" do
      modules = AgentWithMemory.slices()
      assert Jido.Memory.Slice in modules
    end

    test "agent can disable memory slice" do
      modules = AgentWithoutMemory.slices()
      refute Jido.Memory.Slice in modules
    end

    test "memory can be attached after creation via Memory.Agent" do
      agent = AgentWithMemory.new()
      agent = Memory.Agent.ensure(agent)
      assert %Memory{} = Memory.Agent.get(agent)
    end
  end
end
