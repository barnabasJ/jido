defmodule Jido.Pod.Actions.Mutate do
  @moduledoc false

  alias Jido.Pod

  use Jido.Action,
    name: "pod_mutate",
    schema: [
      ops: [type: {:list, :any}, required: true],
      opts: [type: :map, default: %{}]
    ]

  def run(%Jido.Signal{id: signal_id, data: %{ops: ops, opts: opts}}, _slice, _opts, ctx) do
    effect_opts = Keyword.put(Map.to_list(opts || %{}), :mutation_id, signal_id)

    with {:ok, effects} <- Pod.mutation_effects(ctx.agent, ops, effect_opts) do
      {:ok, %{mutation_queued: true, mutation_id: signal_id}, effects}
    end
  end
end
