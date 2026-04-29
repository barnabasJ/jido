defmodule Jido.Dsl.Pod do
  @moduledoc """
  Spark DSL extension for `Jido.Pod`. Adds a `pod do … end` section
  carrying the pod's topology and re-exports the agent / signal_routes
  / schedules sections from `Jido.Dsl.Agent` via `add_extensions:` so
  the user writes a single sectioned module:

      defmodule MyApp.Fulfillment do
        use Jido.Pod

        agent do
          name "fulfillment"
        end

        pod do
          topology %{
            warehouse: %{
              agent: MyApp.Warehouse,
              manager: :fulfillment_warehouse,
              activation: :eager
            },
            shipping: %{
              agent: MyApp.Shipping,
              manager: :fulfillment_shipping,
              activation: :eager
            }
          }
        end
      end
  """

  @pod_section %Spark.Dsl.Section{
    name: :pod,
    describe: "Pod topology and runtime options.",
    schema: [
      topology: [
        type: :any,
        default: %{},
        doc:
          "Map of node names to node specs, or a `%Jido.Pod.Topology{}` struct " <>
            "describing the pod's canonical child agents."
      ],
      plugin: [
        type: :any,
        default: nil,
        doc:
          "Optional override for the reserved pod plugin (default `Jido.Pod.Plugin`). " <>
            "Replacement must declare `path: :pod` and advertise capability `:pod`. " <>
            "Set to `false` to refuse the default and force the host to provide one."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@pod_section],
    add_extensions: [Jido.Dsl.Agent],
    transformers: [
      Jido.Dsl.Pod.Transformers.AttachPodPlugin,
      Jido.Dsl.Pod.Transformers.ResolveTopology
    ]
end
