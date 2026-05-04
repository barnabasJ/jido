defmodule JidoTest.Fixtures.CollidingPodExtension.Transformers.RegisterContribution do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def before?(Jido.Dsl.Agent.Transformers.WalkExtensions), do: true
  def before?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    contributed = Transformer.get_persisted(dsl_state, :jido_contributed_sections, %{})

    {:ok,
     Transformer.persist(
       dsl_state,
       :jido_contributed_sections,
       Map.put(contributed, JidoTest.Fixtures.CollidingPodExtension, :pod)
     )}
  end
end

defmodule JidoTest.Fixtures.CollidingPodExtension do
  @moduledoc """
  Test fixture: a slice that contributes the same `:pod` section name as
  `Jido.Slices.Pod`. Mounting both on the same agent should be rejected at compile
  time by `Jido.Dsl.Agent.Verifiers.NoSectionNameCollisions`.
  """

  use Jido.Slice

  slice do
    name "colliding_pod"
    schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
  end

  signal_routes do
    route "fixture.colliding_pod.noop", JidoTest.PluginTestAction
  end

  capabilities do
    capability :colliding_pod
  end

  @section %Spark.Dsl.Section{
    name: :pod,
    describe: "Test fixture section colliding with Jido.Slices.Pod's `pod do … end`.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [JidoTest.Fixtures.CollidingPodExtension.Transformers.RegisterContribution]
end
