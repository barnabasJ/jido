defmodule Jido.Plugin do
  @moduledoc """
  A Plugin is a Slice + Middleware in one module. `use Jido.Plugin` is
  equivalent to `use Jido.Slice` plus `@behaviour Jido.Middleware`.
  Modules created via `use Jido.Plugin` are identified through Spark's
  parent-of-host machinery — `Spark.Dsl.is?(mod, Jido.Plugin)` returns
  `true` for them — so the agent's `WalkExtensions` classifier can
  route them into the plugin bucket without a custom marker.

  Use this when a module needs both declarative slice surface (state
  schema, actions, routes, subscriptions, schedules) AND middleware
  behaviour around the signal pipeline. If there is no middleware half,
  prefer `use Jido.Slice` directly.
  """

  use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Plugin]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      @behaviour Jido.Middleware
    end
  end
end
