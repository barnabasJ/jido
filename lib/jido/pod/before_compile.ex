defmodule Jido.Pod.BeforeCompile do
  @moduledoc false

  # Emits the pod-wrapping `new/1` override AFTER `Jido.Dsl.Agent.Transformers.GenerateAccessors`
  # has emitted the underlying `def new(opts)` and `defoverridable new: 1`. This
  # is registered as `@before_compile Jido.Pod.BeforeCompile` from `Jido.Pod.__using__/1`
  # so it runs after Spark's `__before_compile__`.

  defmacro __before_compile__(_env) do
    quote do
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
