defmodule Jido.Plugin do
  @moduledoc """
  A Plugin is a Slice + Middleware in one module. `use Jido.Plugin` is
  equivalent to `use Jido.Slice` plus `@behaviour Jido.Middleware`, with
  an additional `__jido_plugin__/0` marker so the agent's
  `WalkExtensions` transformer can route the module into the plugin
  bucket.

  Use this when a module needs both declarative slice surface (state
  schema, actions, routes, subscriptions, schedules) AND middleware
  behaviour around the signal pipeline. If there is no middleware half,
  prefer `use Jido.Slice` directly.
  """

  use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Plugin]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      @doc false
      @spec __jido_slice__() :: true
      def __jido_slice__, do: true

      @doc false
      @spec __jido_plugin__() :: true
      def __jido_plugin__, do: true

      @behaviour Jido.Middleware
    end
  end
end
