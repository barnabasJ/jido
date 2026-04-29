defmodule Jido.Pod.BeforeCompile do
  @moduledoc false

  # Emits `topology/0`, `pod?/0`, and the pod-wrapping `new/1` override
  # AFTER `Jido.Dsl.Agent.Transformers.GenerateAccessors` has emitted the
  # underlying `def new(opts)` and `defoverridable new: 1`. The pod's
  # canonical topology is read from Spark's persisted state — populated
  # by `Jido.Dsl.Pod.Transformers.ResolveTopology` — so the value is in
  # sync with the `pod do topology … end` declaration.

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns the canonical topology for this pod agent."
      @spec topology() :: Jido.Pod.Topology.t()
      def topology, do: Spark.Dsl.Extension.get_persisted(__MODULE__, :resolved_topology)

      @doc "Returns true for pod-wrapped agent modules."
      @spec pod?() :: true
      def pod?, do: true

      @doc """
      Pod-wrapped `new/1`. Seeds the `:pod` slice with the agent module's
      canonical topology before delegating to the base `Jido.Agent.new/1`.
      """
      def new(opts) do
        opts_map = if is_list(opts), do: Map.new(opts), else: opts
        user_state = Map.get(opts_map, :state, %{})

        pod_seed = %{topology: topology(), topology_version: topology().version}

        existing_pod = Map.get(user_state, :pod, %{})
        new_pod = Map.merge(pod_seed, existing_pod)
        new_state = Map.put(user_state, :pod, new_pod)

        opts_with_pod_state =
          opts_map
          |> Map.put(:state, new_state)
          |> Map.to_list()

        super(opts_with_pod_state)
      end
    end
  end
end
