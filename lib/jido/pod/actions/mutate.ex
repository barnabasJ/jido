defmodule Jido.Pod.Actions.Mutate do
  @moduledoc false

  alias Jido.Pod

  use Jido.Action

  action do
    name "pod_mutate"
    path :pod

    schema ops: [type: {:list, :any}, required: true],
           opts: [type: :map, default: %{}]
  end

  def run(%Jido.Signal{id: signal_id, data: %{ops: ops, opts: opts}}, _slice, _opts, ctx) do
    effect_opts = Keyword.put(Map.to_list(opts || %{}), :mutation_id, signal_id)
    Pod.mutation_effects(ctx.agent, ops, effect_opts)
  end
end
