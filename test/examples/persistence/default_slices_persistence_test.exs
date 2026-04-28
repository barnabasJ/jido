defmodule JidoExampleTest.DefaultSlicesPersistenceTest do
  @moduledoc """
  Example test verifying that all three default slices (Thread, Identity, Memory)
  properly survive a hibernate/thaw cycle.

  This test shows:
  - Identity slice state (:keep) is preserved through checkpoint round-trip
  - Memory slice state (:keep) is preserved through checkpoint round-trip
  - Thread slice state (:externalize) is stored separately and rehydrated
  - All three slices together survive a full hibernate/thaw cycle
  - Agents with no slice state initialized still round-trip correctly

  Run with: mix test --include example
  """
  use JidoTest.Case, async: true

  @moduletag :example
  @moduletag timeout: 15_000

  alias Jido.Identity.Agent, as: IdentityAgent
  alias Jido.Memory.Agent, as: MemoryAgent
  alias Jido.Persist
  alias Jido.Storage.ETS
  alias Jido.Thread
  alias Jido.Thread.Agent, as: ThreadAgent

  # ===========================================================================
  # AGENT
  # ===========================================================================

  defmodule FullAgent do
    @moduledoc false
    use Jido.Agent,
      name: "full_agent",
      path: :domain,
      description: "Agent with all three default slices for persistence testing",
      schema: [
        counter: [type: :integer, default: 0],
        status: [type: :atom, default: :idle]
      ]
  end

  # ===========================================================================
  # HELPERS
  # ===========================================================================

  defp unique_table, do: :"default_slices_persist_#{System.unique_integer([:positive])}"

  defp storage(table), do: {ETS, table: table}

  # ===========================================================================
  # TESTS
  # ===========================================================================

  describe "identity survives hibernate/thaw" do
    test "identity struct is preserved through checkpoint round-trip" do
      table = unique_table()

      agent =
        FullAgent.new(id: "identity-1")
        |> IdentityAgent.ensure(profile: %{age: 5, origin: :test})

      agent = %{agent | state: %{agent.state | counter: 10, status: :active}}

      :ok = Persist.hibernate(storage(table), agent)
      {:ok, restored} = Persist.thaw(storage(table), FullAgent, "identity-1")

      assert IdentityAgent.has_identity?(restored)
      assert restored.state.identity.profile[:age] == 5
      assert restored.state.identity.profile[:origin] == :test

      assert restored.state.domain.counter == 10
      assert restored.state.domain.status == :active
    end
  end

  describe "memory survives hibernate/thaw" do
    test "memory spaces are preserved through checkpoint round-trip" do
      table = unique_table()

      agent =
        FullAgent.new(id: "memory-1")
        |> MemoryAgent.ensure()
        |> MemoryAgent.put_in_space(:world, :temperature, 22)
        |> MemoryAgent.append_to_space(:tasks, %{id: "t1", text: "check"})

      agent = %{agent | state: %{agent.state | counter: 5}}

      :ok = Persist.hibernate(storage(table), agent)
      {:ok, restored} = Persist.thaw(storage(table), FullAgent, "memory-1")

      assert MemoryAgent.has_memory?(restored)
      assert MemoryAgent.get_in_space(restored, :world, :temperature) == 22

      tasks_space = MemoryAgent.space(restored, :tasks)
      assert length(tasks_space.data) == 1
      assert Enum.at(tasks_space.data, 0).id == "t1"

      assert restored.state.domain.counter == 5
    end
  end

  describe "all three slices together survive hibernate/thaw" do
    test "comprehensive round-trip with identity, memory, and thread" do
      table = unique_table()

      agent =
        FullAgent.new(id: "all-slices-1")
        |> IdentityAgent.ensure(profile: %{age: 3, origin: :spawned})
        |> MemoryAgent.ensure()
        |> MemoryAgent.put_in_space(:world, :temperature, 18)
        |> MemoryAgent.append_to_space(:tasks, %{id: "t1", text: "deploy"})
        |> ThreadAgent.ensure()
        |> ThreadAgent.append(%{kind: :message, payload: %{role: "user", content: "hello"}})
        |> ThreadAgent.append(%{kind: :message, payload: %{role: "assistant", content: "hi"}})

      agent = %{agent | state: %{agent.state | counter: 42, status: :processing}}

      :ok = Persist.hibernate(storage(table), agent)
      {:ok, restored} = Persist.thaw(storage(table), FullAgent, "all-slices-1")

      # Identity preserved
      assert IdentityAgent.has_identity?(restored)
      assert restored.state.identity.profile[:age] == 3
      assert restored.state.identity.profile[:origin] == :spawned

      # Memory preserved
      assert MemoryAgent.has_memory?(restored)
      assert MemoryAgent.get_in_space(restored, :world, :temperature) == 18
      tasks_space = MemoryAgent.space(restored, :tasks)
      assert length(tasks_space.data) == 1
      assert Enum.at(tasks_space.data, 0).id == "t1"

      # Thread rehydrated from external storage
      assert ThreadAgent.has_thread?(restored)
      rehydrated_thread = ThreadAgent.get(restored)
      assert Thread.entry_count(rehydrated_thread) == 2

      # Regular state preserved
      assert restored.state.domain.counter == 42
      assert restored.state.domain.status == :processing
    end
  end

  describe "slices without state survive hibernate/thaw" do
    test "agent with no slice state initialized round-trips correctly" do
      table = unique_table()

      agent = FullAgent.new(id: "no-slices-1")
      agent = %{agent | state: %{agent.state | counter: 7}}

      :ok = Persist.hibernate(storage(table), agent)
      {:ok, restored} = Persist.thaw(storage(table), FullAgent, "no-slices-1")

      assert restored.state.domain.counter == 7
      refute IdentityAgent.has_identity?(restored)
      refute MemoryAgent.has_memory?(restored)
      refute ThreadAgent.has_thread?(restored)
    end
  end
end
