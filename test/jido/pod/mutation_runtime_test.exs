defmodule JidoTest.Pod.MutationRuntimeTest do
  use JidoTest.Case, async: false

  alias Jido.Agent.InstanceManager
  alias Jido.AgentServer
  alias Jido.Pod
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

  defmodule SlowMountPlugin do
    @moduledoc false

    use Jido.Plugin,
      name: "slow_mount",
      path: :slow_mount,
      actions: [],
      schema: Zoi.object(%{}),
      singleton: true

    @impl true
    def mount(_agent, _config) do
      case :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        pid when is_pid(pid) -> send(pid, :slow_mount_started)
        _other -> :ok
      end

      Process.sleep(1_000)
      {:ok, %{}}
    end
  end

  defmodule SlowBootWorker do
    @moduledoc false
    use Jido.Agent,
      name: "pod_mutation_slow_worker",

      path: :domain,
      schema: [],
      plugins: [SlowMountPlugin]
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

    use Jido.Action, name: "expand_pod", schema: []

    def run(_signal, _slice, _opts, ctx) do
      with {:ok, effects} <-
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
             ) do
        {:ok, %{expanded: true}, effects}
      end
    end
  end

  defmodule SelfMutatingPod do
    @moduledoc false
    use Jido.Pod,
      name: "pod_mutation_self_mutating_pod",
      topology: %{},
      signal_routes: [{"expand", ExpandPodAction}]
  end

  defmodule StuckMutationAction do
    @moduledoc false

    alias Jido.Agent.StateOp

    use Jido.Action, name: "stuck_mutation", schema: []

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, [
        StateOp.set_path([:pod, :mutation], %{
          id: "stuck-id",
          status: :running,
          report: nil,
          error: nil
        })
      ]}
    end
  end

  defmodule StuckMutationPod do
    @moduledoc false
    use Jido.Pod,
      name: "pod_mutation_stuck_pod",
      topology: %{},
      signal_routes: [{"stuck", StuckMutationAction}]
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
      :persistent_term.erase({SlowMountPlugin, :notify_pid})
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
    assert {:ok, planner_state} = AgentServer.state(planner_pid)
    assert planner_state.agent.state.domain.role == "planner"
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
    assert {:ok, planner_pid} = Pod.lookup_node(nested_pid, :planner)
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

    assert {:ok, reviewer_report} = Pod.mutate_and_wait(pod_pid, [Mutation.remove_node("reviewer")])
    assert reviewer_report.status == :completed
    eventually(fn -> not Process.alive?(reviewer_pid) end)
    assert {:error, :unknown_node} = Pod.lookup_node(pod_pid, "reviewer")

    assert {:ok, subtree_report} = Pod.mutate_and_wait(pod_pid, [Mutation.remove_node("planner")])
    assert subtree_report.status == :completed
    eventually(fn -> not Process.alive?(planner_pid) end)
    refute_eventually(Process.alive?(reviewer_pid))
    assert {:error, :unknown_node} = Pod.lookup_node(pod_pid, "planner")
  end

  test "remove mutations recursively tear down nested pod runtimes", %{pod_id: pod_id, jido: jido} do
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
    assert {:ok, nested_planner_pid} = Pod.lookup_node(nested_pid, :planner)

    assert {:ok, report} = Pod.mutate_and_wait(pod_pid, [Mutation.remove_node("nested")])
    assert report.status == :completed

    eventually(fn -> not Process.alive?(nested_pid) end)
    eventually(fn -> not Process.alive?(nested_planner_pid) end)
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
             AgentServer.call(pod_pid, Signal.new!("expand", %{}, source: "/test"))

    state =
      JidoTest.Eventually.eventually_state(
        pod_pid,
        fn state ->
          get_in(state.agent.state, [:pod, :mutation, :status]) == :completed
        end,
        timeout: 5_000
      )

    report = get_in(state.agent.state, [:pod, :mutation, :report])
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

    # Slice reflects the same mutation_id once execute_mutation_plan finishes.
    {:ok, state} = AgentServer.state(pod_pid)
    assert get_in(state.agent.state, [:pod, :mutation, :id]) == id
  end

  test "Pod.mutate while mutation slice is :running returns :mutation_in_progress via the framework error channel",
       %{pod_id: pod_id, jido: jido} do
    {:ok, pod_pid} =
      AgentServer.start_link(agent_module: StuckMutationPod, id: pod_id, jido: jido)

    # Force the mutation slice into :running without actually running anything.
    # AgentServer.call returns once the directive is applied, so when control
    # returns here the slice is in the stuck state.
    assert {:ok, _agent} =
             AgentServer.call(pod_pid, Signal.new!("stuck", %{}, source: "/test"))

    {:ok, state} = AgentServer.state(pod_pid)
    assert get_in(state.agent.state, [:pod, :mutation, :status]) == :running

    result =
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

    # Action error is wrapped via Jido.Error.from_term/1 per ADR 0018 §1; the
    # default selector is never invoked on the error path per ADR 0018 §3.
    # Had the selector run instead, we'd have seen `{:error, :mutation_not_set}`
    # (because the slice id is "stuck-id" and the selector doesn't know that
    # value) or a `{:ok, %{queued: true}}` ack — neither of which contains
    # the substring "mutation_in_progress".
    assert {:error, %Jido.Error.ExecutionError{} = error} = result
    assert inspect(error.details) =~ "mutation_in_progress"
  end

  test "lifecycle signal jido.pod.mutate.completed reaches AgentServer.subscribe subscribers",
       %{pod_id: pod_id, jido: jido} do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    # Subscribe BEFORE the cast — race-free per ADR 0017 §2 because subscribe/4
    # is a synchronous GenServer.call and the lifecycle signal can't fire before
    # the trigger signal's pipeline runs.
    assert {:ok, sub_ref} =
             AgentServer.subscribe(
               pod_pid,
               "jido.pod.mutate.completed",
               fn %{agent: %{state: agent_state}} ->
                 case get_in(agent_state, [:pod, :mutation]) do
                   %{status: :completed, report: report} -> {:ok, report}
                   _other -> :skip
                 end
               end,
               once: true
             )

    assert {:ok, %{queued: true}} =
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

    assert_receive {:jido_subscription, ^sub_ref, %{result: {:ok, report}}}, 5_000
    assert report.status == :completed
    assert report.added == ["planner"]
  end

  test "lifecycle signal jido.pod.mutate.failed reaches subscribers on materialization failure",
       %{pod_id: pod_id, jido: jido} do
    {:ok, pod_pid} = AgentServer.start_link(agent_module: EmptyMutablePod, id: pod_id, jido: jido)

    assert {:ok, sub_ref} =
             AgentServer.subscribe(
               pod_pid,
               "jido.pod.mutate.failed",
               fn %{agent: %{state: agent_state}} ->
                 case get_in(agent_state, [:pod, :mutation]) do
                   %{status: :failed, error: error} -> {:error, error}
                   _other -> :skip
                 end
               end,
               once: true
             )

    # AlternateReviewPod has no pod_module wiring → materialization fails.
    Pod.mutate(
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

    assert_receive {:jido_subscription, ^sub_ref, %{result: {:error, error}}}, 5_000
    assert error.status == :failed
    assert Map.has_key?(error.failures, "bad_nested")
  end

  test "Pod.mutate_and_wait propagates the action error directly without waiting on a lifecycle signal",
       %{pod_id: pod_id, jido: jido} do
    {:ok, pod_pid} =
      AgentServer.start_link(agent_module: StuckMutationPod, id: pod_id, jido: jido)

    # Pre-stick the slice so the action error path returns immediately on the
    # second mutation. mutate_and_wait gets {:error, _} from cast_and_await and
    # unsubscribes both lifecycle subscriptions before returning.
    assert {:ok, _agent} =
             AgentServer.call(pod_pid, Signal.new!("stuck", %{}, source: "/test"))

    result =
      Pod.mutate_and_wait(
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

    assert {:error, %Jido.Error.ExecutionError{} = error} = result
    assert inspect(error.details) =~ "mutation_in_progress"
  end
end
