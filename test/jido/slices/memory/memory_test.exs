defmodule JidoTest.Memory.MemoryTest do
  use ExUnit.Case, async: true

  alias Jido.Slices.Memory.State
  alias Jido.Slices.Memory.Space

  describe "new/0,1" do
    test "creates memory with default spaces" do
      memory = State.new()
      assert %State{} = memory
      assert Map.has_key?(memory.spaces, :world)
      assert Map.has_key?(memory.spaces, :tasks)
    end

    test "world space is a map space" do
      memory = State.new()
      assert Space.map?(memory.spaces.world)
      assert memory.spaces.world.data == %{}
    end

    test "tasks space is a list space" do
      memory = State.new()
      assert Space.list?(memory.spaces.tasks)
      assert memory.spaces.tasks.data == []
    end

    test "generates unique id with mem_ prefix" do
      memory = State.new()
      assert String.starts_with?(memory.id, "mem_")
    end

    test "accepts custom id" do
      memory = State.new(id: "custom-id")
      assert memory.id == "custom-id"
    end

    test "accepts metadata" do
      memory = State.new(metadata: %{agent_id: "a1"})
      assert memory.metadata == %{agent_id: "a1"}
    end

    test "initializes rev to 0" do
      memory = State.new()
      assert memory.rev == 0
    end

    test "sets timestamps" do
      memory = State.new()
      assert is_integer(memory.created_at)
      assert is_integer(memory.updated_at)
      assert memory.created_at == memory.updated_at
    end

    test "accepts custom timestamp" do
      memory = State.new(now: 1_000_000)
      assert memory.created_at == 1_000_000
      assert memory.updated_at == 1_000_000
    end
  end

  describe "reserved_spaces/0" do
    test "returns tasks and world" do
      assert :tasks in State.reserved_spaces()
      assert :world in State.reserved_spaces()
    end
  end

  describe "schema/0" do
    test "returns Zoi schema" do
      assert %{} = State.schema()
    end
  end
end
