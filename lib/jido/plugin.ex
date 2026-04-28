defmodule Jido.Plugin do
  @moduledoc """
  A Plugin is a composable capability — `Jido.Slice` + `Jido.Middleware` in one
  module. `use Jido.Plugin, opts` expands to `use Jido.Slice, opts` plus
  `use Jido.Middleware`.

  Use this when a plugin needs both declarative slice surface (state schema,
  actions, routes) and middleware behaviour around the signal pipeline. If
  there is no middleware half, prefer `use Jido.Slice` directly.
  """

  defmacro __using__(opts) do
    quote do
      use Jido.Slice, unquote(opts)
      use Jido.Middleware

      @doc false
      @spec __jido_plugin__() :: true
      def __jido_plugin__, do: true
    end
  end
end
