defmodule Jido.Dsl.Instance do
  @moduledoc """
  Spark DSL extension for `use Jido` (the application instance
  supervisor).

  Defines a single host-owned section:

    * `instance do … end` — `otp_app`, `storage`, `default_slices`.

  The `Jido.Dsl.Instance.Transformers.GenerateAccessors` transformer
  reads the section options and emits the runtime accessors
  (`__otp_app__/0`, `__jido_storage__/0`, `__default_slices__/0`,
  `start_link/1`, `child_spec/1`, `config/1`, …) that the legacy
  `defmacro Jido.__using__/1` generates today.
  """

  @instance_section %Spark.Dsl.Section{
    name: :instance,
    describe: "Application instance configuration.",
    schema: [
      otp_app: [type: :atom, required: true, doc: "The otp_app for this Jido instance."],
      storage: [type: :any, doc: "Storage adapter spec; defaults to ETS."],
      default_slices: [type: :any, doc: "Override default slices; nil keeps framework defaults."]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@instance_section],
    transformers: [Jido.Dsl.Instance.Transformers.GenerateAccessors]
end
