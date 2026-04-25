defmodule JidoTest.Actions.LifecycleTest do
  use ExUnit.Case, async: true

  alias Jido.Actions.Lifecycle
  alias Jido.Agent.Directive
  alias Jido.AgentServer.ParentRef
  alias Jido.Signal

  defp sig(type, data \\ %{}) do
    Signal.new!(%{type: type, source: "/test", data: data})
  end

  describe "NotifyParent" do
    test "creates emit directive to parent when ctx.parent has a pid" do
      parent_pid = self()
      parent = %ParentRef{pid: parent_pid, id: "parent-1", tag: :child, meta: %{}}

      data = %{signal_type: "child.done", payload: %{result: 42}, source: "/child"}

      {:ok, result, directives} =
        Lifecycle.NotifyParent.run(sig("notify_parent", data), %{}, %{}, %{parent: parent})

      assert result == %{notified: true}
      assert [%Directive.Emit{} = emit] = directives
      assert emit.signal.type == "child.done"
      assert emit.signal.data == %{result: 42}
      assert emit.dispatch == {:pid, [target: parent_pid]}
    end

    test "returns notified: false when ctx.parent is nil (orphaned)" do
      data = %{signal_type: "child.done", payload: %{}, source: "/child"}

      {:ok, result, directives} =
        Lifecycle.NotifyParent.run(sig("notify_parent", data), %{}, %{}, %{parent: nil})

      assert result == %{notified: false}
      assert directives == []
    end
  end

  describe "NotifyPid" do
    test "creates emit directive to specified pid" do
      target = self()

      data = %{
        target_pid: target,
        signal_type: "result.ready",
        payload: %{data: "test"},
        source: "/agent",
        delivery_mode: :async
      }

      {:ok, result, [directive]} =
        Lifecycle.NotifyPid.run(sig("notify_pid", data), %{}, %{}, %{})

      assert result == %{sent_to: target}
      assert %Directive.Emit{} = directive
      assert directive.signal.type == "result.ready"
      assert directive.signal.data == %{data: "test"}
      assert {:pid, opts} = directive.dispatch
      assert Keyword.get(opts, :target) == target
      assert Keyword.get(opts, :delivery_mode) == :async
    end

    test "supports sync delivery mode" do
      target = self()

      data = %{
        target_pid: target,
        signal_type: "sync.request",
        payload: %{},
        source: "/agent",
        delivery_mode: :sync
      }

      {:ok, _result, [directive]} =
        Lifecycle.NotifyPid.run(sig("notify_pid", data), %{}, %{}, %{})

      assert {:pid, opts} = directive.dispatch
      assert Keyword.get(opts, :target) == target
      assert Keyword.get(opts, :delivery_mode) == :sync
    end
  end

  describe "SpawnChild" do
    test "creates spawn_agent directive" do
      data = %{
        agent_module: SomeWorker,
        tag: :worker_1,
        initial_state: %{batch_size: 100},
        meta: %{assigned: true},
        restart: :permanent
      }

      {:ok, result, [directive]} =
        Lifecycle.SpawnChild.run(sig("spawn_child", data), %{}, %{}, %{})

      assert result == %{spawning: :worker_1}
      assert %Directive.SpawnAgent{} = directive
      assert directive.agent == SomeWorker
      assert directive.tag == :worker_1
      assert directive.opts == %{initial_state: %{batch_size: 100}}
      assert directive.meta == %{assigned: true}
      assert directive.restart == :permanent
    end

    test "uses empty opts when no initial_state" do
      data = %{
        agent_module: SomeWorker,
        tag: :worker_2,
        initial_state: %{},
        meta: %{},
        restart: :transient
      }

      {:ok, _result, [directive]} =
        Lifecycle.SpawnChild.run(sig("spawn_child", data), %{}, %{}, %{})

      assert directive.opts == %{}
      assert directive.restart == :transient
    end
  end

  describe "StopSelf" do
    test "creates stop directive with normal reason" do
      {:ok, result, [directive]} =
        Lifecycle.StopSelf.run(sig("stop_self", %{reason: :normal}), %{}, %{}, %{})

      assert result == %{stopping: true, reason: :normal}
      assert %Directive.Stop{} = directive
      assert directive.reason == :normal
    end

    test "supports custom stop reasons" do
      {:ok, result, [directive]} =
        Lifecycle.StopSelf.run(sig("stop_self", %{reason: :work_complete}), %{}, %{}, %{})

      assert result == %{stopping: true, reason: :work_complete}
      assert directive.reason == :work_complete
    end
  end

  describe "StopChild" do
    test "creates stop_child directive" do
      data = %{tag: :worker_1, reason: :normal}

      {:ok, result, [directive]} =
        Lifecycle.StopChild.run(sig("stop_child", data), %{}, %{}, %{})

      assert result == %{stopping_child: :worker_1, reason: :normal}
      assert %Directive.StopChild{} = directive
      assert directive.tag == :worker_1
      assert directive.reason == :normal
    end

    test "supports custom stop reasons" do
      data = %{tag: :processor, reason: :shutdown}

      {:ok, _result, [directive]} =
        Lifecycle.StopChild.run(sig("stop_child", data), %{}, %{}, %{})

      assert directive.reason == :shutdown
    end
  end
end
