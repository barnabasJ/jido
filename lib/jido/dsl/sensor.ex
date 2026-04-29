defmodule Jido.Dsl.Sensor do
  @moduledoc """
  Spark DSL extension for `Jido.Sensor`.

  Defines a single host-owned section:

    * `sensor do … end` — sensor identity (`name`, `description`,
      `category`, `tags`, `vsn`, `schema`).

  The `GenerateAccessors` transformer emits the default `terminate/2`
  callback and its `defoverridable`. Sensor introspection lives in
  `Jido.Dsl.Sensor.Info`.
  """

  @sensor_section %Spark.Dsl.Section{
    name: :sensor,
    describe: "Sensor identity and metadata.",
    schema: [
      name: [
        type: {:custom, Jido.Util, :validate_name, []},
        required: true,
        doc: "Sensor name (letters, numbers, underscores)."
      ],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string],
      schema: [
        type: :any,
        doc: "Zoi schema validating sensor configuration."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@sensor_section],
    transformers: [Jido.Dsl.Sensor.Transformers.GenerateAccessors]
end
