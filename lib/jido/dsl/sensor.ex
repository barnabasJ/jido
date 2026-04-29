defmodule Jido.Dsl.Sensor do
  @moduledoc """
  Spark DSL extension for `Jido.Sensor`.

  Defines a single host-owned section:

    * `sensor do … end` — sensor identity (`name`, `description`,
      `category`, `tags`, `vsn`, `schema`).

  The `GenerateAccessors` transformer reads this section and emits the
  same compile-time accessor surface today's `Jido.Sensor.__using__/1`
  macro emits — `name/0`, `description/0`, `schema/0`, `spec/0`,
  `__sensor_metadata__/0`, plus the default `terminate/2` and the
  associated `defoverridable` block.
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
