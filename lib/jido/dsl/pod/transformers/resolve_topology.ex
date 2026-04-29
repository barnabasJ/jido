defmodule Jido.Dsl.Pod.Transformers.ResolveTopology do
  @moduledoc """
  Resolves the pod's topology declaration into a canonical
  `%Jido.Pod.Topology{}` struct and persists it as
  `:resolved_topology` for `Jido.Pod.BeforeCompile` to read.

  Reads `pod.topology` (a map of node specs or a pre-built
  `%Jido.Pod.Topology{}`) and `agent.name` from the dsl state. The
  topology's `name` is set from the agent's name so the same name
  identifies both the agent module's logical role and the topology
  it owns.
  """

  use Spark.Dsl.Transformer

  alias Jido.Pod.Topology
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    name = Transformer.get_option(dsl_state, [:agent], :name) || ""
    raw_topology = Transformer.get_option(dsl_state, [:pod], :topology, %{})

    topology = build_topology!(name, raw_topology)

    {:ok, Transformer.persist(dsl_state, :resolved_topology, topology)}
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
