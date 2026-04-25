defmodule Jido.Pod.Actions.Mutate do
  @moduledoc false

  alias Jido.Pod

  use Jido.Action,
    name: "pod_mutate",
    schema: [
      ops: [type: {:list, :any}, required: true],
      opts: [type: :map, default: %{}]
    ]

  def run(%Jido.Signal{data: %{ops: ops, opts: opts}}, _slice, _opts, ctx) do
    with {:ok, effects} <- Pod.mutation_effects(ctx.agent, ops, Map.to_list(opts || %{})) do
      mutation_id =
        Enum.find_value(effects, fn
          %Jido.Pod.Directive.ApplyMutation{plan: plan} -> plan.mutation_id
          _other -> nil
        end)

      Pod.mark_mutation_lock(ctx.agent, ctx, mutation_id)
      {:ok, %{mutation_queued: true}, effects}
    end
  end
end
