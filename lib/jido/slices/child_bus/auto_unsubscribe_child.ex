defmodule Jido.Slices.ChildBus.AutoUnsubscribeChild do
  @moduledoc """
  Action invoked by `Jido.Slices.ChildBus` on every `jido.agent.child.exit`
  signal the host agent receives (emitted by
  `AgentServer.handle_child_down/3` when a monitored child process
  dies).

  Looks up the subscription ids previously stored by
  `Jido.Slices.ChildBus.RecordSubscription` for this tag, removes the
  entry from the slice, and emits one
  `Jido.Slices.ChildBus.Directives.UnsubscribeChild` directive per
  sub_id. The directive performs the actual `Jido.Signal.Bus.unsubscribe/2`
  I/O. This action itself is pure — its only outputs are its return
  value (slice with the tag removed + directive list).
  """

  use Jido.Action

  action do
    name "child_bus_auto_unsubscribe_child"
    description "Drop a child's subscription tracking and emit unsubscribe directives."

    schema tag: [type: :any, required: true],
           pid: [type: :any, required: false],
           reason: [type: :any, required: false]
  end

  require Logger

  alias Jido.Slices.ChildBus.Directives.UnsubscribeChild

  def run(%Jido.Signal{data: %{tag: tag}}, slice, _opts, _ctx) do
    with {:ok, bus} <- fetch_bus(slice),
         sub_ids when is_list(sub_ids) <- get_in(slice, [:subscriptions, tag]) do
      directives = Enum.map(sub_ids, &%UnsubscribeChild{bus: bus, sub_id: &1, tag: tag})
      subscriptions = Map.delete(Map.get(slice, :subscriptions, %{}), tag)
      {:ok, Map.put(slice, :subscriptions, subscriptions), directives}
    else
      _ ->
        Logger.debug("child_bus: no subscriptions tracked for #{inspect(tag)}, skipping")
        {:ok, slice, []}
    end
  end

  defp fetch_bus(slice) do
    case Map.get(slice, :bus) do
      bus when is_atom(bus) and not is_nil(bus) -> {:ok, bus}
      _ -> {:error, :no_bus}
    end
  end
end
