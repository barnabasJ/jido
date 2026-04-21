defmodule Jido.Pod.BusPlugin.AutoUnsubscribeChild do
  @moduledoc """
  Action invoked by `Jido.Pod.BusPlugin` on every `jido.agent.child.exit`
  signal the pod receives (emitted by `AgentServer.handle_child_down/3`
  when a monitored child process dies).

  Reads the subscription ids previously stored by
  `Jido.Pod.BusPlugin.AutoSubscribeChild` for this tag, unsubscribes
  each from the pod's bus, and removes the entry from plugin state.

  Returns a state update using `DeletePath` to clear the per-tag entry
  so subscriptions don't accumulate across spawn/exit cycles.
  """

  use Jido.Action,
    name: "pod_auto_unsubscribe_child",
    description: "Unsubscribe a pod child from the pod bus on child.exit.",
    schema: [
      tag: [type: :any, required: true],
      pid: [type: :any, required: false],
      reason: [type: :any, required: false]
    ]

  require Logger

  alias Jido.Agent.StateOp.DeletePath
  alias Jido.Signal.Bus

  @impl true
  def run(%{tag: tag}, %{state: agent_state}) do
    with {:ok, bus} <- fetch_bus(agent_state),
         sub_ids when is_list(sub_ids) <-
           get_in(agent_state, [:__bus_wiring__, :subscriptions, tag]) do
      for sub_id <- sub_ids do
        case Bus.unsubscribe(bus, sub_id) do
          :ok ->
            Logger.debug("pod_bus: unsubscribed #{inspect(tag)} sub=#{inspect(sub_id)}")

          {:error, reason} ->
            Logger.warning(
              "pod_bus: failed to unsubscribe #{inspect(tag)} sub=#{inspect(sub_id)}: #{inspect(reason)}"
            )
        end
      end

      # Clear the per-tag entry from plugin state.
      {:ok, %{},
       [%DeletePath{path: [:__bus_wiring__, :subscriptions, tag]}]}
    else
      _ ->
        # Nothing tracked for this tag; log and move on.
        Logger.debug("pod_bus: no subscriptions tracked for #{inspect(tag)}, skipping")
        {:ok, %{}}
    end
  end

  defp fetch_bus(agent_state) do
    case get_in(agent_state, [:__bus_wiring__, :bus]) do
      bus when is_atom(bus) and not is_nil(bus) -> {:ok, bus}
      _ -> {:error, :no_bus}
    end
  end
end
