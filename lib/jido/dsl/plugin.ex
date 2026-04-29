defmodule Jido.Dsl.Plugin do
  @moduledoc """
  Spark DSL extension for `Jido.Plugin`.

  Plugins are slice + middleware in one module. The DSL re-exports
  `Jido.Dsl.Slice.sections/0` so a `use Jido.Plugin` module shares the
  exact slice surface (`slice do …`, `actions do …`, `signal_routes do …`,
  `subscriptions do …`, `schedules do …`, `capabilities do …`,
  `requires do …`). The accessors transformer is the same one the slice
  uses; the middleware half is wired in via `@behaviour Jido.Middleware`
  inside `Jido.Plugin.__using__/1`.
  """

  use Spark.Dsl.Extension,
    sections: Jido.Dsl.Slice.sections(),
    transformers: [Jido.Dsl.Slice.Transformers.GenerateAccessors]
end
