defmodule Jido.Slices.ChildBus.RecordSubscription do
  @moduledoc """
  Cascade action invoked by the `"child_bus.subscribed"` signal that
  `Jido.Slices.ChildBus.Directives.SubscribeChild` casts back to the
  agent on a successful `Jido.Signal.Bus.subscribe/3` call.

  Appends the new `sub_id` to `slice.subscriptions[tag]` so that
  `Jido.Slices.ChildBus.AutoUnsubscribeChild` can find it on
  `jido.agent.child.exit`.
  """

  use Jido.Action

  action do
    name "child_bus_record_subscription"
    description "Record a successful child-bus subscription's sub_id."

    schema tag: [type: :any, required: true],
           sub_id: [type: :any, required: true],
           path: [type: :string, required: false]
  end

  def run(%Jido.Signal{data: %{tag: tag, sub_id: sub_id}}, slice, _opts, _ctx) do
    current = Map.get(slice, :subscriptions, %{})
    existing = Map.get(current, tag, [])
    next = Map.put(current, tag, [sub_id | existing])
    {:ok, Map.put(slice, :subscriptions, next), []}
  end
end
