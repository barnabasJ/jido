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
      {:ok, %{mutation_queued: true}, effects}
    end
  end
end
