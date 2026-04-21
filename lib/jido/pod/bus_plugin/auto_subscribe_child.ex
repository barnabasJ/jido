defmodule Jido.Pod.BusPlugin.AutoSubscribeChild do
  @moduledoc """
  Action invoked by `Jido.Pod.BusPlugin` on every `jido.agent.child.started`
  signal the pod receives.

  Reads the child's module and pid out of the signal data, pulls the
  target bus out of the plugin's state slice (`:__bus_wiring__`), and
  calls `Jido.Signal.Bus.subscribe/3` once per path declared by the
  child's `signal_routes/0`. Errors during subscription are logged but
  do not abort the pod — a missing bus or a duplicate subscription will
  show up in the logs, not as a hard crash.

  The pod's own `maybe_track_child_started/2` still runs on the same
  signal and is responsible for putting the child in
  `state.children` — this action is purely additive.
  """

  use Jido.Action,
    name: "pod_auto_subscribe_child",
    description: "Subscribe a pod child's pid to its signal_routes paths on the pod bus.",
    schema: [
      pid: [type: :any, required: true],
      child_module: [type: :atom, required: true],
      tag: [type: :any, required: true],
      parent_id: [type: :string, required: false],
      child_id: [type: :string, required: false],
      child_partition: [type: :any, required: false],
      meta: [type: :map, required: false]
    ]

  require Logger

  alias Jido.Signal.Bus

  @impl true
  def run(params, %{state: agent_state}) do
    with {:ok, bus} <- fetch_bus(agent_state),
         {:ok, routes} <- fetch_routes(params.child_module) do
      for route <- routes do
        path = elem(route, 0)

        case Bus.subscribe(bus, path, dispatch: {:pid, target: params.pid}) do
          {:ok, _sub_id} ->
            Logger.debug(
              "pod_bus: subscribed #{inspect(params.child_module)}/#{inspect(params.tag)} to #{inspect(path)} on #{inspect(bus)}"
            )

          {:error, reason} ->
            Logger.warning(
              "pod_bus: failed to subscribe #{inspect(params.child_module)} to #{inspect(path)} on #{inspect(bus)}: #{inspect(reason)}"
            )
        end
      end

      {:ok, %{}}
    else
      {:error, reason} ->
        Logger.warning("pod_bus: skipped auto-subscribe — #{reason}")
        {:ok, %{}}
    end
  end

  defp fetch_bus(agent_state) do
    case get_in(agent_state, [:__bus_wiring__, :bus]) do
      bus when is_atom(bus) and not is_nil(bus) -> {:ok, bus}
      _ -> {:error, "no :bus configured under :__bus_wiring__"}
    end
  end

  defp fetch_routes(child_module) do
    if function_exported?(child_module, :signal_routes, 0) do
      {:ok, child_module.signal_routes()}
    else
      {:error, "#{inspect(child_module)} does not export signal_routes/0"}
    end
  end
end
