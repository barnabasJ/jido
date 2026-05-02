defmodule Jido.Slices.Identity.Transformers.RegisterContribution do
  @moduledoc """
  Registers `Jido.Slices.Identity` as the slice module that owns the
  contributed `identity do … end` section in the host agent's
  `:jido_contributed_sections` map.

  `Jido.Dsl.Agent.Transformers.WalkExtensions.read_contributed_block/2`
  reads this map to know which contributed-section opts to merge into a
  given slice's instance config. By persisting
  `%{Jido.Slices.Identity => :identity}`, this transformer makes the
  `identity do … end` block opts flow into the Identity slice's instance
  config when the user mounts `slices do slice :identity, Jido.Slices.Identity end`.

  Pure `Spark.Dsl.Transformer.persist/3` — no Jido-custom callbacks.
  """

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
       Map.put(contributed, Jido.Slices.Identity, :identity)
     )}
  end
end
