defmodule Jido.Dsl.Action do
  @moduledoc """
  Spark DSL extension for `Jido.Action`.

  Defines a single host-owned section:

    * `action do … end` — action identity (`name`, `description`,
      `category`, `tags`, `vsn`, `path`, `compensation`, `schema`,
      `output_schema`).

  The `GenerateAccessors` transformer reads this section and emits the
  same compile-time accessors today's `Jido.Action.__using__/1` macro
  emits — `name/0`, `description/0`, `category/0`, `tags/0`, `vsn/0`,
  `path/0`, `schema/0`, `output_schema/0`, `validate_params/1`,
  `validate_output/1`, `to_json/0`, `to_tool/0`,
  `__action_metadata__/0`, plus a `defoverridable` block over the
  lifecycle hook surface.
  """

  @action_section %Spark.Dsl.Section{
    name: :action,
    describe: "Action identity and metadata.",
    schema: [
      name: [
        type: {:custom, Jido.Util, :validate_name, []},
        required: true,
        doc: "Action name (letters, numbers, underscores)."
      ],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string],
      path: [
        type: :any,
        doc:
          "Atom slice key this action operates on. " <>
            "Defaults to the agent's `path:` at routing time."
      ],
      compensation: [
        type: :any,
        default: %{enabled: false, max_retries: 1, timeout: 5000},
        doc: "Compensation declaration; see `Jido.Action.Schema`."
      ],
      schema: [
        type: {:custom, Jido.Action, :validate_io_schema, []},
        default: [],
        doc: "Zoi or NimbleOptions schema validating this action's input."
      ],
      output_schema: [
        type: {:custom, Jido.Action, :validate_io_schema, []},
        default: [],
        doc: "Zoi or NimbleOptions schema validating this action's output."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@action_section],
    transformers: [Jido.Dsl.Action.Transformers.GenerateAccessors]
end
