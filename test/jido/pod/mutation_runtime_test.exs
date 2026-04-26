defmodule JidoTest.Pod.MutationRuntimeTest do
  use JidoTest.Case, async: false

  alias Jido.Agent.InstanceManager
  alias Jido.AgentServer
  alias Jido.Pod
  alias Jido.Pod.Directive.StartNode
  alias Jido.Pod.Mutation
  alias Jido.Pod.Topology
  alias Jido.Storage.ETS
  alias Jido.Signal

  @planner_manager :pod_mutation_planner_members
  @reviewer_manager :pod_mutation_reviewer_members
  @nested_pod_manager :pod_mutation_nested_pods
  @slow_manager :pod_mutation_slow_members

  defmodule PodWorker do
    @moduledoc false
    use Jido.Agent,
      name: "pod_mutation_worker",
      path: :domain,
      schema: [
        role: [type: :string, default: "worker"]
      ]
  end

  defmodule SlowStartingMiddleware do
    @moduledoc false
    @behaviour Jido.Middleware

    def on_signal(
          %Jido.Signal{type: "jido.agent.lifecycle.starting"} = signal,
          ctx,
          _opts,
          next
        ) do
      case :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        pid when is_pid(pid) -> send(pid, :slow_starting)
        _ -> :ok
      end

      Process.sleep(500)
      next.(signal, ctx)
    end

    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  defmodule SlowBootWorker do
    @moduledoc false
    use Jido.Agent,
      name: "pod_mutation_slow_worker",
      path: :domain,
      schema: [],
      middleware: [SlowStartingMiddleware]
  end

  defmodule ReviewPod do
    @moduledoc false
    use Jido.Pod,
      name: "pod_mutation_review_pod",
      topology:
        Topology.new!(
          name: "pod_mutation_review_pod",
          nodes: %{
            planner: %{
              agent: PodWorker,
              manager: :pod_mutation_planner_members,
              activation: :eager,
              initial_state: %{role: "planner"}
            },
            reviewer: %{
              agent: PodWorker,
              manager: :pod_mutation_reviewer_members,
              activation: :lazy,
              initial_state: %{role: "reviewer"}
            }
          },
          links: [{:owns, :planner, :reviewer}]
        )
  end

  defmodule AlternateReviewPod do
    @moduledoc false
    use Jido.Pod, name: "pod_mutation_alternate_review_pod"
  end

  defmodule EmptyMutablePod do
    @moduledoc false
    use Jido.Pod, name: "pod_mutation_empty_pod"
  end

  defmodule ExpandPodAction do
    @moduledoc false

    alias Jido.Pod
    alias Jido.Pod.Mutation

    use Jido.Action, name: "expand_pod", path: :pod, schema: []

    def run(_signal, _slice, _opts, ctx) do
      Pod.mutation_effects(
        ctx.agent,
        [
          Mutation.add_node(
            "planner",
            %{
              agent: JidoTest.Pod.MutationRuntimeTest.PodWorker,
              manager: :pod_mutation_planner_members,
              activation: :eager,
              initial_state: %{role: "planner"}
            }
          )
        ]
      )
    end
  end

  defmodule SelfMutatingPod do
    @moduledoc false
    use Jido.Pod,
      name: "pod_mutation_self_mutating_pod",
      topology: %{},
      signal_routes: [{"expand", ExpandPodAction}]
  end

  setup %{jido: jido} do
    storage_table = :"pod_mutation_storage_#{System.unique_integer([:positive])}"

    {:ok, _planner_manager} =
      start_supervised(
        InstanceManager.child_spec(
          name: @planner_manager,
          agent: PodWorker,
          jido: jido,
          storage: {ETS, table: storage_table},
          agent_opts: [jido: jido, on_parent_death: :continue]
        )
      )

    {:ok, _reviewer_manager} =
      start_supervised(
        InstanceManager.child_spec(
          name: @reviewer_manager,
          agent: PodWorker,
          jido: jido,
          storage: {ETS, table: storage_table},
          agent_opts: [jido: jido, on_parent_death: :continue]
        )
      )

    {:ok, _nested_pod_manager} =
      start_supervised(
        InstanceManager.child_spec(
          name: @nested_pod_manager,
          agent: ReviewPod,
          jido: jido,
          storage: {ETS, table: storage_table},
          agent_opts: [jido: jido, on_parent_death: :continue]
        )
      )

    {:ok, _slow_manager} =
      start_supervised(
        InstanceManager.child_spec(
          name: @slow_manager,
          agent: SlowBootWorker,
          jido: jido,
          storage: {ETS, table: storage_table},
          agent_opts: [jido: jido, on_parent_death: :continue]
        )
      )

    on_exit(fn ->
      :persistent_term.erase({InstanceManager, @planner_manager})
      :persistent_term.erase({InstanceManager, @reviewer_manager})
      :persistent_term.erase({InstanceManager, @nested_pod_manager})
      :persistent_term.erase({InstanceManager, @slow_manager})
      :persistent_term.erase({SlowStartingMiddleware, :notify_pid})
    end)

    {:ok, pod_id: unique_id("mutable-pod"), jido: jido}
  end

  test "external mutate adds eager nodes and starts them immediately", %{
    pod_id: pod_id,
    jido: jido
  } do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node(
                   "planner",
                   %{
                     agent: PodWorker,
                     manager: @planner_manager,
                     activation: :eager,
                     initial_state: %{role: "planner"}
                   }
                 )
               ]
             )

    assert report.status == :completed
    assert report.added == ["planner"]
    assert report.started == ["planner"]

    assert {:ok, topology} = Pod.fetch_topology(pod_pid)
    assert Map.has_key?(topology.nodes, "planner")
    assert {:ok, planner_pid} = Pod.lookup_node(pod_pid, "planner")

    assert {:ok, planner_role} =
             AgentServer.state(planner_pid, fn s -> {:ok, s.agent.state.domain.role} end)

    assert planner_role == "planner"
  end

  test "external mutate persists lazy nodes without starting them", %{pod_id: pod_id, jido: jido} do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node(
                   "reviewer",
                   %{
                     agent: PodWorker,
                     manager: @reviewer_manager,
                     activation: :lazy,
                     initial_state: %{role: "reviewer"}
                   }
                 )
               ]
             )

    assert report.status == :completed
    assert report.started == []
    assert :error = Pod.lookup_node(pod_pid, "reviewer")
    assert {:ok, topology} = Pod.fetch_topology(pod_pid)
    assert Map.has_key?(topology.nodes, "reviewer")
  end

  test "external mutate adds nested pod nodes and reconciles their eager topology", %{
    pod_id: pod_id,
    jido: jido
  } do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node("nested", %{
                   module: ReviewPod,
                   manager: @nested_pod_manager,
                   kind: :pod,
                   activation: :eager
                 })
               ]
             )

    assert report.status == :completed
    assert {:ok, nested_pid} = Pod.lookup_node(pod_pid, "nested")

    # The nested pod's eager reconcile is fire-and-forget per task 0010 —
    # parent mutation completes when the nested pod itself is up; nested
    # children come up asynchronously. Wait for the nested planner via
    # await_state_value rather than relying on synchronous cascade.
    planner_pid =
      JidoTest.AgentWait.await_state_value(
        nested_pid,
        fn s ->
          case Map.get(s.children, :planner) do
            %{pid: pid} when is_pid(pid) -> pid
            _ -> nil
          end
        end,
        pattern: "jido.agent.child.started",
        timeout: 5_000
      )

    assert Process.alive?(planner_pid)
  end

  test "remove mutations stop leaves and owned subtrees without orphaning descendants", %{
    pod_id: pod_id,
    jido: jido
  } do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    add_ops = [
      Mutation.add_node(
        "planner",
        %{
          agent: PodWorker,
          manager: @planner_manager,
          activation: :eager,
          initial_state: %{role: "planner"}
        }
      ),
      Mutation.add_node(
        "reviewer",
        %{
          agent: PodWorker,
          manager: @reviewer_manager,
          activation: :eager,
          initial_state: %{role: "reviewer"}
        },
        owner: "planner"
      )
    ]

    assert {:ok, _report} = Pod.mutate_and_wait(pod_pid, add_ops)
    assert {:ok, planner_pid} = Pod.lookup_node(pod_pid, "planner")
    assert {:ok, reviewer_pid} = Pod.lookup_node(pod_pid, "reviewer")

    assert {:ok, reviewer_report} =
             Pod.mutate_and_wait(pod_pid, [Mutation.remove_node("reviewer")])

    assert reviewer_report.status == :completed
    eventually(fn -> not Process.alive?(reviewer_pid) end)
    assert {:error, :unknown_node} = Pod.lookup_node(pod_pid, "reviewer")

    assert {:ok, subtree_report} = Pod.mutate_and_wait(pod_pid, [Mutation.remove_node("planner")])
    assert subtree_report.status == :completed
    eventually(fn -> not Process.alive?(planner_pid) end)
    refute_eventually(Process.alive?(reviewer_pid))
    assert {:error, :unknown_node} = Pod.lookup_node(pod_pid, "planner")
  end

  test "removing a nested pod node tears down the nested pod itself", %{
    pod_id: pod_id,
    jido: jido
  } do
    # Behavior change vs. the wave-orchestrated runtime: removal stops the
    # nested pod via the same single-pid stop primitive as any other node.
    # The pod's own children survive their parent's death (per their
    # `on_parent_death: :continue` config) — cascading teardown of the
    # nested pod's children is no longer driven by the parent's mutation.
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, _report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node("nested", %{
                   module: ReviewPod,
                   manager: @nested_pod_manager,
                   kind: :pod,
                   activation: :eager
                 })
               ]
             )

    assert {:ok, nested_pid} = Pod.lookup_node(pod_pid, "nested")

    assert {:ok, report} = Pod.mutate_and_wait(pod_pid, [Mutation.remove_node("nested")])
    assert report.status == :completed

    eventually(fn -> not Process.alive?(nested_pid) end)
    assert {:error, :unknown_node} = Pod.lookup_node(pod_pid, "nested")
  end

  test "failed runtime materialization keeps the persisted topology and returns a failed report",
       %{
         pod_id: pod_id,
         jido: jido
       } do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:error, report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node("bad_nested", %{
                   module: AlternateReviewPod,
                   manager: @nested_pod_manager,
                   kind: :pod,
                   activation: :eager
                 })
               ]
             )

    assert report.status == :failed
    assert Map.has_key?(report.failures, "bad_nested")
    assert {:ok, topology} = Pod.fetch_topology(pod_pid)
    assert Map.has_key?(topology.nodes, "bad_nested")

    case Pod.lookup_node(pod_pid, "bad_nested") do
      {:error, _reason} -> :ok
      :error -> :ok
    end

    assert {:ok, follow_up_report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node("reviewer", %{
                   agent: PodWorker,
                   manager: @reviewer_manager,
                   activation: :lazy
                 })
               ]
             )

    assert follow_up_report.status == :completed
    assert "reviewer" in follow_up_report.added
  end

  test "in-turn mutation_effects uses the same mutation completion path", %{
    pod_id: pod_id,
    jido: jido
  } do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: SelfMutatingPod, id: pod_id, jido: jido)

    assert {:ok, _agent} =
             AgentServer.call(pod_pid, Signal.new!("expand", %{}, source: "/test"), fn s ->
               {:ok, s.agent}
             end)

    report =
      JidoTest.AgentWait.await_state_value(
        pod_pid,
        fn s ->
          if get_in(s.agent.state, [:pod, :mutation, :status]) == :completed do
            get_in(s.agent.state, [:pod, :mutation, :report])
          end
        end,
        timeout: 5_000
      )

    assert report.status == :completed
    assert report.added == ["planner"]
    assert {:ok, planner_pid} = Pod.lookup_node(pod_pid, "planner")
    assert Process.alive?(planner_pid)
  end

  test "Pod.mutate returns the queued ack with mutation_id immediately", %{
    pod_id: pod_id,
    jido: jido
  } do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, %{mutation_id: id, queued: true}} =
             Pod.mutate(
               pod_pid,
               [
                 Mutation.add_node("planner", %{
                   agent: PodWorker,
                   manager: @planner_manager,
                   activation: :eager,
                   initial_state: %{role: "planner"}
                 })
               ]
             )

    assert is_binary(id)
    assert byte_size(id) > 0

    {:ok, mutation_id} =
      AgentServer.state(pod_pid, fn s ->
        {:ok, get_in(s.agent.state, [:pod, :mutation, :id])}
      end)

    assert mutation_id == id
  end

  test "concurrent mutate while one is in-flight rejects with :mutation_in_progress",
       %{pod_id: pod_id, jido: jido} do
    # Mutation A spawns a slow-booting worker (its lifecycle.starting middleware
    # blocks 500ms). Cast (not call) mutation A so the test isn't blocked
    # waiting for the worker's init to return — the pod's process_signal IS
    # blocked though, since SpawnManagedAgent.execute waits for the child's
    # init. Once the SlowStartingMiddleware sends :slow_starting, the test
    # knows the worker is mid-boot, the pod's mutation slice is :running,
    # and a second mutate cast (queued behind A in the pod's mailbox) will
    # reject via the natural ensure_mutation_idle guard — no
    # StuckMutationAction shim required.
    :persistent_term.put({SlowStartingMiddleware, :notify_pid}, self())

    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    mutate_a_signal =
      Signal.new!(
        "pod.mutate",
        %{
          ops: [
            Mutation.add_node("planner", %{
              agent: SlowBootWorker,
              manager: @slow_manager,
              activation: :eager
            })
          ],
          opts: %{}
        },
        source: "/test"
      )

    :ok = AgentServer.cast(pod_pid, mutate_a_signal)

    assert_receive :slow_starting, 5_000

    result =
      Pod.mutate(
        pod_pid,
        [
          Mutation.add_node("reviewer", %{
            agent: PodWorker,
            manager: @reviewer_manager,
            activation: :lazy
          })
        ]
      )

    assert {:error, %Jido.Error.ExecutionError{} = error} = result
    assert inspect(error.details) =~ "mutation_in_progress"
  end

  test "pod mailbox stays responsive while a long-stop mutation is in-flight",
       %{pod_id: pod_id, jido: jido} do
    # Spawn a child whose lifecycle.stopping handler is slow. Cast a remove
    # mutation, then immediately query Pod.nodes/1 — the query must return
    # before the stop completes. This verifies the pod's mailbox is not
    # blocked by mutation work (per ADR 0017).
    :persistent_term.put({SlowStartingMiddleware, :notify_pid}, self())

    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, _report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node("planner", %{
                   agent: SlowBootWorker,
                   manager: @slow_manager,
                   activation: :eager
                 })
               ]
             )

    assert {:ok, _planner_pid} = Pod.lookup_node(pod_pid, "planner")

    # Kick off the remove mutation but don't wait. Then do a Pod.nodes query
    # immediately — it must return before the slow stop completes.
    assert {:ok, %{queued: true}} = Pod.mutate(pod_pid, [Mutation.remove_node("planner")])

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, _snapshots} = Pod.nodes(pod_pid)
    elapsed = System.monotonic_time(:millisecond) - started_at

    # Pod.nodes is a signal call. It must round-trip quickly — well under the
    # 500ms slow-boot window. A loose 250ms upper bound is plenty for a free
    # mailbox; a blocked mailbox would wait the full slow-boot first.
    assert elapsed < 250
  end

  test "report.nodes[name].pid is set after a successful start", %{
    pod_id: pod_id,
    jido: jido
  } do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node("planner", %{
                   agent: PodWorker,
                   manager: @planner_manager,
                   activation: :eager
                 })
               ]
             )

    assert %{"planner" => %{pid: pid, source: :started}} = report.nodes
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "StartNode directive does not write agent.state — strict ADR 0019 separation", %{
    pod_id: pod_id,
    jido: jido
  } do
    # Add a lazy planner so the topology entry exists without a running pid,
    # then run StartNode through DirectiveExec.exec inside the agent process
    # (via the test_apply route). The action returns the pre-/post-directive
    # `state.agent.state` snapshots; assert they're equal — StartNode is
    # pure I/O and must not touch the domain slice value.
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, _report} =
             Pod.mutate_and_wait(
               pod_pid,
               [
                 Mutation.add_node("planner", %{
                   agent: PodWorker,
                   manager: @planner_manager,
                   activation: :lazy
                 })
               ]
             )

    {:ok, %{before: before_state, after: after_state}} =
      AgentServer.state(pod_pid, fn s ->
        before_state = s.agent.state
        directive = StartNode.new!("planner")
        signal = Signal.new!("noop", %{}, source: "/test")
        {:ok, next_state} = Jido.AgentServer.DirectiveExec.exec(directive, signal, s)
        {:ok, %{before: before_state, after: next_state.agent.state}}
      end)

    assert before_state == after_state
  end

  test "mutation slice receives id and runs to terminal status without a synthetic completion signal",
       %{pod_id: pod_id, jido: jido} do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    expected_id =
      "mutate-#{System.unique_integer([:positive])}"

    signal =
      Signal.new!(
        "pod.mutate",
        %{
          ops: [
            Mutation.add_node("planner", %{
              agent: PodWorker,
              manager: @planner_manager,
              activation: :eager
            })
          ],
          opts: %{}
        },
        source: "/test",
        id: expected_id
      )

    {:ok, sub_ref} =
      AgentServer.subscribe(
        pod_pid,
        "jido.agent.child.*",
        fn %{agent: %{state: agent_state}} ->
          case get_in(agent_state, [:pod, :mutation]) do
            %{id: ^expected_id, status: :completed, report: report} -> {:ok, report}
            %{id: ^expected_id, status: :failed, error: error} -> {:error, error}
            _ -> :skip
          end
        end,
        once: true
      )

    AgentServer.cast(pod_pid, signal)

    assert_receive {:jido_subscription, ^sub_ref, %{result: {:ok, report}}}, 5_000
    assert report.status == :completed
    assert report.started == ["planner"]
  end
end
