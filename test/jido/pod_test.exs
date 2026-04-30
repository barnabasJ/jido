defmodule JidoTest.PodTest do
  use ExUnit.Case, async: true

  alias Jido.Pod
  alias Jido.Pod.Plugin
  alias Jido.Pod.Topology
  alias Jido.Pod.Topology.Node
  alias Jido.Storage.ETS

  defmodule WorkerAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "pod_test_worker"
    end
  end

  defmodule CustomPodPlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "custom_pod"

      schema(
        Zoi.object(%{
          topology: Zoi.any() |> Zoi.optional(),
          topology_version: Zoi.integer() |> Zoi.default(1),
          metadata: Zoi.map() |> Zoi.default(%{})
        })
      )
    end

    capabilities do
      capability :pod
    end
  end

  defmodule UserPlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "pod_test_user_plugin"
      schema Zoi.object(%{})
    end
  end

  defmodule ExamplePod do
    @moduledoc false
    use Jido.Pod

    agent do
      name "example_pod"
    end

    pod do
      topology(%{
        planner: %{agent: WorkerAgent, manager: :planner_nodes, activation: :eager},
        reviewer: %{agent: WorkerAgent, manager: :reviewer_nodes}
      })
    end
  end

  defmodule EmptyPod do
    @moduledoc false
    use Jido.Pod

    agent do
      name "empty_pod"
    end
  end

  defmodule CustomPluginPod do
    @moduledoc false
    use Jido.Pod

    agent do
      name "custom_plugin_pod"
    end

    pod do
      plugin CustomPodPlugin

      topology(%{
        worker: %{agent: WorkerAgent, manager: :worker_nodes}
      })
    end
  end

  test "use Jido.Pod wraps an agent module with a canonical topology" do
    assert ExamplePod.pod?()
    assert %Topology{name: "example_pod"} = ExamplePod.topology()

    assert %Node{activation: :eager, module: WorkerAgent} = ExamplePod.topology().nodes.planner

    assert Enum.any?(Jido.Dsl.Agent.Info.plugin_instances(ExamplePod), fn instance ->
             instance.module == Plugin and instance.path == :pod
           end)
  end

  test "use Jido.Pod defaults omitted topology to an empty topology" do
    assert EmptyPod.pod?()
    assert %Topology{name: "empty_pod", nodes: %{}, links: []} = EmptyPod.topology()

    agent = EmptyPod.new()
    assert {:ok, %Topology{name: "empty_pod", nodes: %{}}} = Pod.fetch_topology(agent)
  end

  test "default_slices can replace the reserved pod plugin" do
    assert Enum.any?(Jido.Dsl.Agent.Info.plugin_instances(CustomPluginPod), fn instance ->
             instance.module == CustomPodPlugin and instance.path == :pod
           end)

    agent = CustomPluginPod.new()

    assert {:ok, %{metadata: %{}}} = Pod.fetch_state(agent)
    assert {:ok, %Topology{name: "custom_plugin_pod"}} = Pod.fetch_topology(agent)
  end

  test "plugins option resolves aliased plugin modules before pod opts are escaped" do
    suffix = System.unique_integer([:positive])
    pod_mod = Module.concat(__MODULE__, :"AliasedPluginPod#{suffix}")
    pod_name = "aliased_plugin_pod_#{suffix}"

    Code.compile_string("""
    defmodule #{inspect(pod_mod)} do
      @moduledoc false
      alias #{inspect(UserPlugin)}, as: UserPlugin

      use Jido.Pod, middleware: [UserPlugin]

      agent do
        name #{inspect(pod_name)}
      end

      slices do
        slice :pod_test_user_plugin, UserPlugin
      end
    end
    """)

    assert Enum.any?(Jido.Dsl.Agent.Info.plugin_instances(pod_mod), fn instance ->
             instance.module == UserPlugin and instance.path == :pod_test_user_plugin
           end)
  end

  test "disabling the reserved pod plugin raises at compile time" do
    message = ~r/Jido.Pod requires a pod plugin under pod/

    assert_raise Spark.Error.DslError, message, fn ->
      Code.compile_string("""
      defmodule JidoTest.PodDisabledPluginPod do
        use Jido.Pod

        agent do
          name "disabled_pod"
        end

        pod do
          plugin false
          topology %{worker: %{agent: #{inspect(WorkerAgent)}, manager: :workers}}
        end
      end
      """)
    end
  end

  test "topology data structures can be mutated purely" do
    topology =
      Topology.from_nodes!("mutable_topology", %{
        planner: %{agent: WorkerAgent, manager: :planner_nodes}
      })

    assert {:ok, topology} =
             Topology.put_node(
               topology,
               :reviewer,
               %{agent: WorkerAgent, manager: :reviewer_nodes, activation: :eager}
             )

    assert {:ok, %Node{activation: :eager}} = Topology.fetch_node(topology, :reviewer)

    topology =
      topology
      |> then(fn topology ->
        assert {:ok, topology} = Topology.put_link(topology, {:depends_on, :reviewer, :planner})
        topology
      end)
      |> Topology.delete_node(:planner)

    refute Map.has_key?(topology.nodes, :planner)
    assert [] == topology.links
  end

  test "topology data structures accept string node names" do
    topology =
      Topology.from_nodes!("string_named_topology", %{
        "planner" => %{agent: WorkerAgent, manager: :planner_nodes}
      })

    assert {:ok, topology} =
             Topology.put_node(
               topology,
               "reviewer",
               %{agent: WorkerAgent, manager: :reviewer_nodes, activation: :eager}
             )

    assert {:ok, %Node{activation: :eager}} = Topology.fetch_node(topology, "reviewer")
    assert {:ok, topology} = Topology.put_link(topology, {:depends_on, "reviewer", "planner"})

    assert {:ok, ["planner", "reviewer"]} =
             Topology.dependency_order(topology, ["reviewer", "planner"])
  end

  test "mutated pod topology persists through existing storage adapters" do
    table = :"pod_test_storage_#{System.unique_integer([:positive])}"
    storage = {ETS, table: table}
    agent = ExamplePod.new(id: "persisted-pod")

    {:ok, agent} =
      Pod.update_topology(agent, fn topology ->
        Topology.put_node(
          topology,
          :auditor,
          %{agent: WorkerAgent, manager: :auditor_nodes}
        )
      end)

    assert :ok = Jido.Persist.hibernate(storage, agent)
    assert {:ok, thawed} = Jido.Persist.thaw(storage, ExamplePod, "persisted-pod")
    assert {:ok, topology} = Pod.fetch_topology(thawed)
    assert Map.has_key?(topology.nodes, :auditor)
  end

  test "mutated pod topology persists string-named nodes through existing storage adapters" do
    table = :"pod_test_storage_#{System.unique_integer([:positive])}"
    storage = {ETS, table: table}
    agent = EmptyPod.new(id: "persisted-dynamic-pod")

    {:ok, agent} =
      Pod.update_topology(agent, fn topology ->
        Topology.put_node(
          topology,
          "auditor",
          %{agent: WorkerAgent, manager: :auditor_nodes}
        )
      end)

    assert :ok = Jido.Persist.hibernate(storage, agent)
    assert {:ok, thawed} = Jido.Persist.thaw(storage, EmptyPod, "persisted-dynamic-pod")
    assert {:ok, topology} = Pod.fetch_topology(thawed)
    assert Map.has_key?(topology.nodes, "auditor")
  end

  test "update_topology advances topology version only when the topology changes" do
    agent = EmptyPod.new()

    assert {:ok, %{topology_version: 1}} = Pod.fetch_state(agent)
    assert {:ok, %Topology{version: 1}} = Pod.fetch_topology(agent)

    assert {:ok, unchanged_agent} = Pod.update_topology(agent, & &1)
    assert {:ok, %{topology_version: 1}} = Pod.fetch_state(unchanged_agent)
    assert {:ok, %Topology{version: 1}} = Pod.fetch_topology(unchanged_agent)

    assert {:ok, changed_agent} =
             Pod.update_topology(unchanged_agent, fn topology ->
               Topology.put_node(
                 topology,
                 "auditor",
                 %{agent: WorkerAgent, manager: :auditor_nodes}
               )
             end)

    assert {:ok, %{topology_version: 2}} = Pod.fetch_state(changed_agent)
    assert {:ok, %Topology{version: 2} = topology} = Pod.fetch_topology(changed_agent)
    assert Map.has_key?(topology.nodes, "auditor")

    assert {:ok, changed_again_agent} =
             Pod.update_topology(changed_agent, fn topology ->
               Topology.put_node(
                 topology,
                 "reviewer",
                 %{agent: WorkerAgent, manager: :reviewer_nodes}
               )
             end)

    assert {:ok, %{topology_version: 3}} = Pod.fetch_state(changed_again_agent)
    assert {:ok, %Topology{version: 3} = topology} = Pod.fetch_topology(changed_again_agent)
    assert Map.has_key?(topology.nodes, "reviewer")

    assert {:error, _reason} =
             Pod.update_topology(changed_again_agent, fn topology ->
               Topology.put_link(topology, {:depends_on, "auditor", "auditor"})
             end)

    assert {:ok, %{topology_version: 3}} = Pod.fetch_state(changed_again_agent)
  end

  test "put_topology shares the same topology version semantics as update_topology" do
    agent = EmptyPod.new()

    changed_topology =
      Topology.from_nodes!("empty_pod", %{
        "auditor" => %{agent: WorkerAgent, manager: :auditor_nodes}
      })

    assert {:ok, changed_agent} = Pod.put_topology(agent, changed_topology)
    assert {:ok, %{topology_version: 2}} = Pod.fetch_state(changed_agent)
    assert {:ok, %Topology{version: 2} = topology} = Pod.fetch_topology(changed_agent)
    assert Map.has_key?(topology.nodes, "auditor")

    assert {:ok, unchanged_agent} = Pod.put_topology(changed_agent, changed_topology)
    assert {:ok, %{topology_version: 2}} = Pod.fetch_state(unchanged_agent)
    assert {:ok, %Topology{version: 2}} = Pod.fetch_topology(unchanged_agent)

    expanded_topology =
      Topology.put_node(changed_topology, "reviewer", %{
        agent: WorkerAgent,
        manager: :reviewer_nodes
      })
      |> elem(1)

    assert {:ok, expanded_agent} = Pod.put_topology(unchanged_agent, expanded_topology)
    assert {:ok, %{topology_version: 3}} = Pod.fetch_state(expanded_agent)
    assert {:ok, %Topology{version: 3} = topology} = Pod.fetch_topology(expanded_agent)
    assert Map.has_key?(topology.nodes, "reviewer")
  end
end
