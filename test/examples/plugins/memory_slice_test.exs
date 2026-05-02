defmodule JidoExampleTest.MemorySliceTest do
  @moduledoc """
  Example test demonstrating Memory as a default slice.

  This test shows:
  - Every agent gets `Jido.Slices.Memory` automatically (default singleton slice)
  - Initializing and mutating memory through the slice's actions via `cmd/2`:
    `Jido.Slices.Memory.Actions.{Ensure, PutInSpace, AppendToSpace, EnsureSpace,
    DeleteSpace}`
  - Reading memory directly off `agent.state[:memory]` and via
    `Jido.Slices.Memory.State` read-only functions
  - Disabling the memory slice with `default_slices: %{memory: false}`

  Run with: mix test --include example
  """
  use JidoTest.Case, async: false

  @moduletag :example
  @moduletag timeout: 15_000

  alias Jido.Slices.Memory.Space
  alias Jido.Slices.Memory.State

  # ===========================================================================
  # ACTIONS
  # ===========================================================================

  defmodule UpdateWorldAction do
    @moduledoc false
    use Jido.Action

    action do
      name "update_world"
      schema key: [type: :atom, required: true], value: [type: :any, required: true]
    end

    def run(%Jido.Signal{data: %{key: key, value: value}}, slice, _opts, _ctx) do
      alias Jido.Slices.Memory.Space
      alias Jido.Slices.Memory.State

      memory =
        case slice do
          %State{} = m -> m
          _ -> State.new()
        end

      world = Map.get(memory.spaces, :world, Space.new_kv())
      updated_world = %{world | data: Map.put(world.data, key, value), rev: world.rev + 1}

      updated_memory = %{
        memory
        | spaces: Map.put(memory.spaces, :world, updated_world),
          rev: memory.rev + 1
      }

      {:ok, updated_memory, []}
    end
  end

  # ===========================================================================
  # AGENTS
  # ===========================================================================

  defmodule MemoryAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "memory_agent"
      path :domain
      description "Agent with default memory slice"
      schema status: [type: :atom, default: :idle]
    end
  end

  defmodule NoMemoryAgent do
    @moduledoc false
    use Jido.Agent,
      default_slices: %{memory: false}

    agent do
      name "no_memory_agent"
      path :domain
      description "Agent with memory slice disabled"
      schema value: [type: :integer, default: 0]
    end
  end

  # ===========================================================================
  # TESTS
  # ===========================================================================

  describe "memory slice is a default singleton" do
    test "new agent has no memory until initialized on demand" do
      agent = MemoryAgent.new()

      assert is_nil(agent.state[:memory])
    end

    test "Ensure action initializes memory on demand" do
      agent = MemoryAgent.new()

      {:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})

      assert %State{} = agent.state[:memory]
      assert Map.has_key?(agent.state.memory.spaces, :world)
      assert Map.has_key?(agent.state.memory.spaces, :tasks)
    end
  end

  describe "space operations" do
    test "put and get in map space (:world)" do
      agent = MemoryAgent.new()
      {:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})

      {:ok, agent, []} =
        MemoryAgent.cmd(
          agent,
          {Jido.Slices.Memory.Actions.PutInSpace, %{space: :world, key: :temperature, value: 22}}
        )

      assert State.get_in_space(agent.state.memory, :world, :temperature) == 22

      {:ok, agent, []} =
        MemoryAgent.cmd(
          agent,
          {Jido.Slices.Memory.Actions.PutInSpace, %{space: :world, key: :humidity, value: 65}}
        )

      assert State.get_in_space(agent.state.memory, :world, :humidity) == 65
      assert State.get_in_space(agent.state.memory, :world, :temperature) == 22
    end

    test "append to list space (:tasks)" do
      agent = MemoryAgent.new()
      {:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})

      {:ok, agent, []} =
        MemoryAgent.cmd(
          agent,
          {Jido.Slices.Memory.Actions.AppendToSpace,
           %{space: :tasks, item: %{id: "t1", text: "Check sensor"}}}
        )

      {:ok, agent, []} =
        MemoryAgent.cmd(
          agent,
          {Jido.Slices.Memory.Actions.AppendToSpace,
           %{space: :tasks, item: %{id: "t2", text: "Report status"}}}
        )

      tasks_space = State.space(agent.state.memory, :tasks)
      assert Space.list?(tasks_space)
      assert length(tasks_space.data) == 2
      assert Enum.map(tasks_space.data, & &1.id) == ["t1", "t2"]
    end

    test "EnsureSpace creates a new custom space" do
      agent = MemoryAgent.new()
      {:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})

      refute State.has_space?(agent.state.memory, :custom)

      {:ok, agent, []} =
        MemoryAgent.cmd(
          agent,
          {Jido.Slices.Memory.Actions.EnsureSpace, %{space: :custom, default: %{}}}
        )

      assert State.has_space?(agent.state.memory, :custom)

      custom_space = State.space(agent.state.memory, :custom)
      assert Space.map?(custom_space)
    end

    test "DeleteSpace works for custom spaces" do
      agent = MemoryAgent.new()
      {:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})

      {:ok, agent, []} =
        MemoryAgent.cmd(
          agent,
          {Jido.Slices.Memory.Actions.EnsureSpace, %{space: :scratch, default: %{}}}
        )

      assert State.has_space?(agent.state.memory, :scratch)

      {:ok, agent, []} =
        MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.DeleteSpace, %{space: :scratch}})

      refute State.has_space?(agent.state.memory, :scratch)
    end

    test "DeleteSpace returns error on reserved spaces" do
      agent = MemoryAgent.new()
      {:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})

      assert {:error, err} =
               MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.DeleteSpace, %{space: :world}})

      original = err.details[:reason] || err

      assert Exception.message(original.details.original_exception) =~
               "cannot delete reserved space"
    end
  end

  describe "memory state via cmd/2" do
    test "cmd/2 with action preserves memory changes" do
      agent = MemoryAgent.new()
      {:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})

      {:ok, agent, []} =
        MemoryAgent.cmd(agent, {UpdateWorldAction, %{key: :location, value: "lab"}})

      assert %State{} = agent.state[:memory]
      assert State.get_in_space(agent.state.memory, :world, :location) == "lab"
    end

    test "multiple cmd/2 calls accumulate memory" do
      agent = MemoryAgent.new()
      {:ok, agent, []} = MemoryAgent.cmd(agent, {Jido.Slices.Memory.Actions.Ensure, %{}})

      {:ok, agent, []} = MemoryAgent.cmd(agent, {UpdateWorldAction, %{key: :x, value: 1}})
      {:ok, agent, []} = MemoryAgent.cmd(agent, {UpdateWorldAction, %{key: :y, value: 2}})

      assert State.get_in_space(agent.state.memory, :world, :x) == 1
      assert State.get_in_space(agent.state.memory, :world, :y) == 2
    end
  end

  describe "disabling memory slice" do
    test "agent with memory disabled has no memory capability" do
      agent = NoMemoryAgent.new()

      assert is_nil(agent.state[:memory])
      refute Map.has_key?(agent.state, :memory)

      modules = Jido.Dsl.Agent.Info.slices(NoMemoryAgent)
      refute Jido.Slices.Memory in modules
    end
  end
end
