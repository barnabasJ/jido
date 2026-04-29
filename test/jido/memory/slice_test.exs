defmodule JidoTest.Memory.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Memory
  alias Jido.Memory.Actions
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

    test "exposes the eight Jido.Memory.Actions.* modules via actions/0" do
      action_set = MapSet.new(MemorySlice.actions())

      assert MapSet.equal?(
               action_set,
               MapSet.new([
                 Actions.Ensure,
                 Actions.PutSpace,
                 Actions.UpdateSpace,
                 Actions.EnsureSpace,
                 Actions.DeleteSpace,
                 Actions.PutInSpace,
                 Actions.DeleteFromSpace,
                 Actions.AppendToSpace
               ])
             )
    end

    test "schema is bound to Jido.Memory.schema/0" do
      assert MemorySlice.schema() == Memory.schema()
    end

    test "exposes one signal route per action" do
      route_types =
        MemorySlice.signal_routes()
        |> Enum.map(fn
          {type, _action} -> type
          {type, _action, _opts} -> type
        end)

      assert "jido.memory.ensure" in route_types
      assert "jido.memory.put_space" in route_types
      assert "jido.memory.update_space" in route_types
      assert "jido.memory.ensure_space" in route_types
      assert "jido.memory.delete_space" in route_types
      assert "jido.memory.put_in_space" in route_types
      assert "jido.memory.delete_from_space" in route_types
      assert "jido.memory.append_to_space" in route_types
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
      end
    end

    defmodule AgentWithoutMemory do
      use Jido.Agent,
        default_slices: %{memory: false}

      agent do
        name "memory_slice_test_no_memory"
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

    test "PutInSpace action mutates agent.state.memory.spaces[:world]" do
      agent = AgentWithMemory.new()

      {:ok, agent, []} =
        AgentWithMemory.cmd(
          agent,
          {Actions.PutInSpace, %{space: :world, key: :temperature, value: 22}}
        )

      assert agent.state.memory.spaces[:world].data == %{temperature: 22}
    end
  end
end
