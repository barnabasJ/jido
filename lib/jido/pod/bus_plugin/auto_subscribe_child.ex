defmodule Jido.Pod.BusPlugin.AutoSubscribeChild do
  @moduledoc """
  Action invoked by `Jido.Pod.BusPlugin` on every `jido.agent.child.started`
  signal the pod receives.

  Reads the child's module and pid out of the signal data, pulls the
  target bus out of the slice's state (`:pod_bus`), and
  calls `Jido.Signal.Bus.subscribe/3` once per path declared by the
  child's `signal_routes/0`. The returned subscription ids are written
  back to the plugin's state so `AutoUnsubscribeChild` can undo them
  when the child exits.

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

  alias Jido.Agent.StateOp.SetPath
  alias Jido.Signal.Bus

  def run(%Jido.Signal{data: params}, agent_state, _opts, _ctx) do
    with {:ok, bus} <- fetch_bus(agent_state),
         {:ok, routes} <- fetch_routes(params.child_module) do
      sub_ids =
        Enum.reduce(routes, [], fn route, acc ->
          path = elem(route, 0)

          case Bus.subscribe(bus, path, dispatch: {:pid, target: params.pid}) do
            {:ok, sub_id} ->
              Logger.debug(
                "pod_bus: subscribed #{inspect(params.child_module)}/#{inspect(params.tag)} to #{inspect(path)} on #{inspect(bus)}"
              )

              [sub_id | acc]

            {:error, reason} ->
              Logger.warning(
                "pod_bus: failed to subscribe #{inspect(params.child_module)} to #{inspect(path)} on #{inspect(bus)}: #{inspect(reason)}"
              )

              acc
          end
        end)

      # Record sub_ids by tag via an explicit SetPath state op so
      # AutoUnsubscribeChild's DeletePath is the structural mirror image.
      # This matches the agent's "state changes as directives" contract
      # instead of relying on DeepMerge semantics on the returned result.
      {:ok, %{},
       [%SetPath{path: [:pod_bus, :subscriptions, params.tag], value: sub_ids}]}
    else
      {:error, reason} ->
        Logger.warning("pod_bus: skipped auto-subscribe — #{reason}")
        {:ok, %{}}
    end
  end

  defp fetch_bus(agent_state) do
    case get_in(agent_state, [:pod_bus, :bus]) do
      bus when is_atom(bus) and not is_nil(bus) -> {:ok, bus}
      _ -> {:error, "no :bus configured under :pod_bus slice"}
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
