defmodule JidoTest.Thread.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Thread
  alias Jido.Thread.Slice, as: ThreadSlice

  describe "slice metadata" do
    test "name is thread" do
      assert ThreadSlice.name() == "thread"
    end

    test "path is :thread" do
      assert ThreadSlice.path() == :thread
    end

    test "is singleton" do
      assert ThreadSlice.singleton?() == true
    end

    test "has thread capability" do
      assert :thread in ThreadSlice.capabilities()
    end

    test "has no actions" do
      assert ThreadSlice.actions() == []
    end

    test "schema is nil (no auto-initialization)" do
      assert ThreadSlice.schema() == nil
    end
  end

  describe "manifest" do
    test "singleton is true in manifest" do
      manifest = ThreadSlice.manifest()
      assert manifest.singleton == true
    end

    test "path is :thread in manifest" do
      manifest = ThreadSlice.manifest()
      assert manifest.path == :thread
    end
  end

  describe "Persist.Transform implementation" do
    test "externalize/1 strips a Thread struct to a {id, rev} pointer" do
      thread =
        Thread.new(id: "t-1")
        |> Thread.append(%{kind: :message, payload: %{text: "hello"}})

      assert %{id: "t-1", rev: 1} = ThreadSlice.externalize(thread)
    end

    test "externalize/1 returns nil for nil input" do
      assert nil == ThreadSlice.externalize(nil)
    end

    test "externalize/1 reflects rev count for multi-entry threads" do
      thread =
        Thread.new(id: "t-2")
        |> Thread.append(%{kind: :message, payload: %{text: "one"}})
        |> Thread.append(%{kind: :message, payload: %{text: "two"}})
        |> Thread.append(%{kind: :message, payload: %{text: "three"}})

      assert %{id: "t-2", rev: 3} = ThreadSlice.externalize(thread)
    end

    test "reinstate/1 passes through (rehydration is the Persister's job)" do
      pointer = %{id: "t-1", rev: 5}
      assert ThreadSlice.reinstate(pointer) == pointer
    end
  end

  describe "agent integration" do
    defmodule AgentWithThread do
      use Jido.Agent, name: "thread_slice_test_agent", path: :domain
    end

    defmodule AgentWithoutThread do
      use Jido.Agent,
        name: "thread_slice_test_no_thread",
        path: :domain,
        default_slices: %{thread: false}
    end

    test "agent includes thread slice by default" do
      modules = AgentWithThread.slices()
      assert Jido.Thread.Slice in modules
    end

    test "agent.state[:thread] starts nil (no auto-init)" do
      agent = AgentWithThread.new()
      assert Map.get(agent.state, :thread) == nil
    end

    test "agent can disable thread slice" do
      modules = AgentWithoutThread.slices()
      refute Jido.Thread.Slice in modules
    end

    test "thread can be attached after creation via Thread.Agent" do
      agent = AgentWithThread.new()
      agent = Thread.Agent.ensure(agent)
      assert %Thread{} = Thread.Agent.get(agent)
    end
  end
end
