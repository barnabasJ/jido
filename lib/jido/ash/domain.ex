defmodule Jido.Ash.Domain do
  @moduledoc """
  Ash domain extension for declaring Jido agent composition metadata.
  """

  alias Jido.Ash.Domain.SliceMount

  @slice %Spark.Dsl.Entity{
    name: :slice,
    describe: "Mounts an Ash-backed slice resource or Jido slice at a domain-owned path.",
    target: SliceMount,
    args: [:path, :module],
    schema: [
      path: [type: :atom, required: true],
      module: [type: :atom, required: true],
      options: [type: {:or, [:keyword_list, :map]}, default: []]
    ]
  }

  @jido_agent_section %Spark.Dsl.Section{
    name: :jido_agent,
    describe: "Domain-backed Jido agent composition.",
    schema: [
      name: [type: :string, required: true],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string]
    ],
    entities: [@slice]
  }

  use Spark.Dsl.Extension,
    sections: [@jido_agent_section],
    transformers: [Jido.Ash.Domain.Transformers.BuildAgentComposition]
end
