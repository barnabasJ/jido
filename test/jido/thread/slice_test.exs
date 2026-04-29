defmodule JidoTest.Thread.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Dsl.Agent.Info, as: AgentInfo
  alias Jido.Dsl.Slice.Info, as: SliceInfo
  alias Jido.Thread
  alias Jido.Thread.Actions
  alias Jido.Thread.Slice, as: ThreadSlice

  describe "slice metadata" do
    test "name is thread" do
      assert SliceInfo.name(ThreadSlice) == "thread"
    end

    test "path is :thread" do
      assert SliceInfo.path(ThreadSlice) == :thread
    end

    test "has thread capability" do
      assert :thread in SliceInfo.capabilities(ThreadSlice)
    end

    test "exposes Thread.Actions.{Ensure,Append,Clear} via actions/1" do
      action_set = MapSet.new(SliceInfo.actions(ThreadSlice))

      assert MapSet.equal?(
               action_set,
               MapSet.new([Actions.Ensure, Actions.Append, Actions.Clear])
             )
    end

    test "schema is bound to Jido.Thread.schema/0" do
      assert SliceInfo.schema(ThreadSlice) == Thread.schema()
    end

    test "exposes one signal route per action" do
      route_types =
        ThreadSlice
        |> SliceInfo.signal_routes()
        |> Enum.map(fn
          {type, _action} -> type
          {type, _action, _opts} -> type
        end)

      assert "jido.thread.ensure" in route_types
      assert "jido.thread.append" in route_types
      assert "jido.thread.clear" in route_types
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
      use Jido.Agent

      agent do
        name "thread_slice_test_agent"
      end
    end

    defmodule AgentWithoutThread do
      use Jido.Agent,
        default_slices: %{thread: false}

      agent do
        name "thread_slice_test_no_thread"
      end
    end

    test "agent includes thread slice by default" do
      assert Jido.Thread.Slice in AgentInfo.slices(AgentWithThread)
    end

    test "agent.state[:thread] starts nil (lazy init)" do
      agent = AgentWithThread.new()
      assert Map.get(agent.state, :thread) == nil
    end

    test "agent can disable thread slice" do
      refute Jido.Thread.Slice in AgentInfo.slices(AgentWithoutThread)
    end

    test "thread can be attached after creation via Thread.Agent" do
      agent = AgentWithThread.new()
      agent = Thread.Agent.ensure(agent)
      assert %Thread{} = Thread.Agent.get(agent)
    end

    test "Append action mutates agent.state.thread" do
      agent = AgentWithThread.new()

      {:ok, agent, []} =
        AgentWithThread.cmd(
          agent,
          {Actions.Append, %{entry: %{kind: :message, payload: %{text: "hi"}}}}
        )

      assert Thread.entry_count(agent.state.thread) == 1
    end
  end
end
