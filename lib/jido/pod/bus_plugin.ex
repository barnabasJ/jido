defmodule Jido.Pod.BusPlugin do
  @moduledoc """
  Wires pod child agents to a `Jido.Signal.Bus` automatically.

  When a pod child boots, `Jido.Pod.Runtime` passes the pod as the child's
  parent, so the child emits `jido.agent.child.started` back to the pod
  during its post-init hook. This slice routes that signal to an action that
  subscribes the child's pid to every path declared by the child agent's
  `signal_routes/0`, against the bus named in the slice's config.

  The slice does not start the bus — the caller is responsible for starting
  `Jido.Signal.Bus` (or wiring one up via a Jido instance). The slice
  assumes the bus already exists and is addressable by the configured atom
  at subscription time.

  ## Usage

      defmodule MyApp.Fulfillment do
        use Jido.Pod,
          name: "fulfillment",
          plugins: [{Jido.Pod.BusPlugin, %{bus: :fulfillment_bus}}],
          topology: %{
            warehouse: %{module: MyApp.Warehouse, manager: :fulfillment_warehouse, activation: :eager},
            shipping:  %{module: MyApp.Shipping,  manager: :fulfillment_shipping,  activation: :eager}
          }
      end

  ## Routes

  The slice's `signal_routes:` are framework-namespaced (`jido.agent.*`) and
  are added to the agent's signal router **without** the slice's own prefix —
  see `Jido.Plugin.Routes.expand_routes/1`, which leaves `jido.*` routes
  unprefixed.
  """

  alias Jido.Pod.BusPlugin.AutoSubscribeChild
  alias Jido.Pod.BusPlugin.AutoUnsubscribeChild

  use Jido.Slice,
    name: "pod_bus",
    description: "Auto-subscribes pod children to a named signal bus.",
    path: :pod_bus,
    actions: [AutoSubscribeChild, AutoUnsubscribeChild],
    signal_routes: [
      {"jido.agent.child.started", AutoSubscribeChild},
      {"jido.agent.child.exit", AutoUnsubscribeChild}
    ],
    schema:
      Zoi.object(%{
        bus:
          Zoi.atom(description: "Name of the Jido.Signal.Bus to subscribe children on.")
          |> Zoi.refine({__MODULE__, :validate_bus_atom, []}),
        subscriptions:
          Zoi.map(description: "Per-tag subscription-id lists, used for cleanup on child.exit.")
          |> Zoi.default(%{})
      }),
    capabilities: [:bus_wiring]

  @doc false
  @spec validate_bus_atom(atom(), keyword()) :: :ok | {:error, String.t()}
  def validate_bus_atom(nil, _opts),
    do: {:error, "Jido.Pod.BusPlugin requires a `:bus` atom; got nil"}

  def validate_bus_atom(value, _opts) when is_atom(value), do: :ok

  def validate_bus_atom(other, _opts),
    do: {:error, "Jido.Pod.BusPlugin requires a `:bus` atom; got #{inspect(other)}"}
end
