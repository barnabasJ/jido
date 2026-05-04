defmodule Jido.Slices.ChildBus do
  @moduledoc """
  Wires an agent's children to a `Jido.Signal.Bus` automatically.

  When a child agent boots under a parent that declared this slice, the
  child emits `jido.agent.child.started` back to the parent during its
  post-init hook. This slice routes that signal to an action that
  subscribes the child's pid to every path declared by the child
  agent's `signal_routes/0`, against the bus named in the slice's
  config.

  The slice does not start the bus — the caller is responsible for
  starting `Jido.Signal.Bus` (or wiring one up via a Jido instance).
  The slice assumes the bus already exists and is addressable by the
  configured atom at subscription time.

  ## Usage

      defmodule MyApp.Fulfillment do
        use Jido.Agent, extensions: [Jido.Pod]

        agent do
          name "fulfillment"
        end

        slices do
          slice :pod, Jido.Pod
          slice :child_bus, {Jido.Slices.ChildBus, %{bus: :my_bus}}
        end

        pod do
          topology %{
            warehouse: %{module: MyApp.Warehouse, manager: :fulfillment_warehouse, activation: :eager},
            shipping:  %{module: MyApp.Shipping,  manager: :fulfillment_shipping,  activation: :eager}
          }
        end
      end

  ## Routes

  Bare slices register their `signal_routes/0` with **absolute** paths;
  slice-declared routes do not get a per-instance prefix (see
  `Jido.Slice.Instance`). The two routes here
  (`jido.agent.child.started`, `jido.agent.child.exit`) are
  framework-emitted child lifecycle signals.
  """

  alias Jido.Slices.ChildBus.AutoSubscribeChild
  alias Jido.Slices.ChildBus.AutoUnsubscribeChild

  use Jido.Slice

  slice do
    name "child_bus"
    description "Auto-subscribes an agent's children to a named signal bus."

    schema Zoi.object(%{
             bus:
               Zoi.atom(description: "Name of the Jido.Signal.Bus to subscribe children on.")
               |> Zoi.refine({__MODULE__, :validate_bus_atom, []}),
             subscriptions:
               Zoi.map(
                 description: "Per-tag subscription-id lists, used for cleanup on child.exit."
               )
               |> Zoi.default(%{})
           })
  end

  signal_routes do
    route "jido.agent.child.started", AutoSubscribeChild
    route "jido.agent.child.exit", AutoUnsubscribeChild
  end

  capabilities do
    capability :bus_wiring
  end

  @doc false
  @spec validate_bus_atom(atom(), keyword()) :: :ok | {:error, String.t()}
  def validate_bus_atom(nil, _opts),
    do: {:error, "Jido.Slices.ChildBus requires a `:bus` atom; got nil"}

  def validate_bus_atom(value, _opts) when is_atom(value), do: :ok

  def validate_bus_atom(other, _opts),
    do: {:error, "Jido.Slices.ChildBus requires a `:bus` atom; got #{inspect(other)}"}
end
