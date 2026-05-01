defmodule Jido.Pod.Transformers.ResolveTopology do
  @moduledoc """
  Resolves the pod's topology declaration into a canonical
  `%Jido.Pod.Topology{}` struct and writes it back into the contributed
  `pod` section's `:opts` so downstream consumers (the auto-generated
  `Jido.Pod.Info.pod_topology/1` accessor and
  `Jido.Dsl.Agent.Transformers.WalkExtensions.read_contributed_block/2`)
  see the normalized struct rather than the raw map.

  Reads `pod.topology` (a map of node specs or a pre-built
  `%Jido.Pod.Topology{}`) and `agent.name` from the host's dsl_state. The
  topology's `name` is set from the agent's name so the same name
  identifies both the agent module's logical role and the topology
  it owns.
  """

  use Spark.Dsl.Transformer

  alias Jido.Pod.Topology
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def before?(Jido.Dsl.Agent.Transformers.WalkExtensions), do: true
  def before?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    name = Transformer.get_option(dsl_state, [:agent], :name) || ""
    raw_topology = Transformer.get_option(dsl_state, [:pod], :topology, %{})

    topology = build_topology!(name, raw_topology)

    section_state = Map.get(dsl_state, [:pod], %{opts: []})
    new_opts = Keyword.put(section_state.opts || [], :topology, topology)
    new_section = Map.put(section_state, :opts, new_opts)

    {:ok, Map.put(dsl_state, [:pod], new_section)}
  end

  defp build_topology!(name, %Topology{} = topology) do
    case Topology.with_name(topology, name) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        raise Spark.Error.DslError,
          message: "Invalid pod topology name: #{inspect(reason)}",
          path: [:pod, :topology]
    end
  end

  defp build_topology!(name, raw_topology) when is_map(raw_topology) do
    case Topology.from_nodes(name, raw_topology) do
      {:ok, topology} ->
        topology

      {:error, reason} ->
        raise Spark.Error.DslError,
          message: "Invalid pod topology: #{inspect(reason)}",
          path: [:pod, :topology]
    end
  end

  defp build_topology!(_name, other) do
    raise Spark.Error.DslError,
      message:
        "Invalid pod topology: expected a map or %Jido.Pod.Topology{}, got: #{inspect(other)}",
      path: [:pod, :topology]
  end
end
