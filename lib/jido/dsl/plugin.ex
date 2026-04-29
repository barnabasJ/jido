defmodule Jido.Dsl.Plugin do
  @moduledoc """
  Spark DSL extension for `Jido.Plugin`.

  Plugins are slice + middleware in one module. The DSL re-exports
  the slice DSL's sections so a `use Jido.Plugin` module shares the
  exact slice surface (`slice do …`, `signal_routes do …`,
  `subscriptions do …`, `schedules do …`, `capabilities do …`,
  `requires do …`). Introspection lives in `Jido.Dsl.Plugin.Info`,
  which delegates to `Jido.Dsl.Slice.Info`; the middleware half is
  wired in via `@behaviour Jido.Middleware` inside `Jido.Plugin`.
  """

  use Spark.Dsl.Extension, sections: Jido.Dsl.Slice.sections()
end
