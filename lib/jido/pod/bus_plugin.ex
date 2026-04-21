defmodule Jido.Pod.BusPlugin do
  @moduledoc """
  Wires pod child agents to a `Jido.Signal.Bus` automatically.

  When a pod child boots, `Jido.Pod.Runtime` passes the pod as the child's
  parent, so the child emits `jido.agent.child.started` back to the pod
  during its post-init hook. This plugin routes that signal to an action
  that subscribes the child's pid to every path declared by the child
  agent's `signal_routes/0`, against the bus named in the plugin's config.

  The plugin does not start the bus — the caller is responsible for
  starting `Jido.Signal.Bus` (or wiring one up via a Jido instance).
  The plugin assumes it already exists and is addressable by the
  `bus` atom at subscription time.

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

  With the pod running, publishing a signal to `:fulfillment_bus` on a
  path that matches one of the children's `signal_routes:` will be
  dispatched to that child by the bus — no manual `Bus.subscribe/3`
  calls required.

  ## Scope

  This plugin handles pod children started via the pod's own `ensure_node`
  / `reconcile` path (which uses `Jido.Agent.InstanceManager`). It relies
  on `jido.agent.child.started` being emitted, which `Jido.Pod.Runtime`
  already takes care of on the parent-adoption path.

  ## Routes

  The plugin uses the `signal_routes/1` callback (rather than the
  compile-time `signal_routes:` option) so the route is added to the
  agent's signal router **without** the plugin name prefix — we're
  hooking a system signal (`jido.agent.child.started`) that isn't in
  our plugin's namespace.
  """

  alias Jido.Pod.BusPlugin.AutoSubscribeChild

  use Jido.Plugin,
    name: "pod_bus",
    description: "Auto-subscribes pod children to a named signal bus.",
    state_key: :__bus_wiring__,
    actions: [AutoSubscribeChild],
    schema:
      Zoi.object(%{
        bus:
          Zoi.atom(description: "Name of the Jido.Signal.Bus to subscribe children on.")
      }),
    capabilities: [:bus_wiring]

  @impl Jido.Plugin
  def mount(_agent, %{bus: bus}) when is_atom(bus) and not is_nil(bus) do
    {:ok, %{bus: bus}}
  end

  def mount(_agent, config) do
    {:error,
     "Jido.Pod.BusPlugin requires a `:bus` atom in its config, got: #{inspect(config)}"}
  end

  @impl Jido.Plugin
  def signal_routes(_config) do
    # Returned routes are added to the agent's signal router unprefixed —
    # we want to match the system signal `jido.agent.child.started`
    # verbatim, not `pod_bus.jido.agent.child.started`.
    [{"jido.agent.child.started", AutoSubscribeChild}]
  end
end
