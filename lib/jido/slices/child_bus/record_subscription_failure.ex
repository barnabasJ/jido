defmodule Jido.Slices.ChildBus.RecordSubscriptionFailure do
  @moduledoc """
  Cascade action invoked by the `"child_bus.subscribe_failed"` signal
  that `Jido.Slices.ChildBus.Directives.SubscribeChild` casts when
  `Jido.Signal.Bus.subscribe/3` returns `{:error, reason}`.

  Appends `%{path: …, reason: …, at: …}` to
  `slice.failed_subscriptions[tag]` so the gap is observable in slice
  state instead of being silently swallowed by a `Logger.warning`.
  """

  use Jido.Action

  action do
    name "child_bus_record_subscription_failure"
    description "Record a child-bus subscription that failed at the bus."

    schema tag: [type: :any, required: true],
           path: [type: :string, required: true],
           reason: [type: :any, required: true],
           child_module: [type: :atom, required: false]
  end

  def run(%Jido.Signal{data: %{tag: tag, path: path, reason: reason}}, slice, _opts, _ctx) do
    failures = Map.get(slice, :failed_subscriptions, %{})
    entry = %{path: path, reason: reason, at: System.monotonic_time(:millisecond)}
    next = Map.update(failures, tag, [entry], &[entry | &1])
    {:ok, Map.put(slice, :failed_subscriptions, next), []}
  end
end
