defmodule Jido.Dsl.AgentExtensionsOrderTest do
  use ExUnit.Case, async: true

  # Pin the middleware-chain ordering. ADR 0014 §"Middleware chain composition"
  # defined the chain as `middleware ++ plugin_middleware_in_declaration_order`.
  # Under the new shape, the chain is the order of plugin / middleware entries
  # in the `extensions: [...]` keyword list. For agents that previously had
  # both `middleware:` and `plugins:` filled, the migration must list
  # middleware before plugins to preserve "all middleware first, then all
  # plugin middleware halves" unless the user chooses to interleave.

  defmodule MiddlewareA do
    @moduledoc false
    use Jido.Middleware

    @impl true
    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  defmodule MiddlewareB do
    @moduledoc false
    use Jido.Middleware

    @impl true
    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  defmodule MiddlewareC do
    @moduledoc false
    use Jido.Middleware

    @impl true
    def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
  end

  defmodule OrderedAgent do
    @moduledoc false
    use Jido.Agent,
      middleware: [MiddlewareA, MiddlewareB, MiddlewareC]

    agent do
      name "ordered_agent"
    end
  end

  test "middleware/0 preserves the `extensions: […]` keyword-list order" do
    assert [{MiddlewareA, _}, {MiddlewareB, _}, {MiddlewareC, _}] =
             Jido.Dsl.Agent.Info.middleware(OrderedAgent)
  end

  defmodule InterleavedAgent do
    @moduledoc false
    use Jido.Agent,
      middleware: [MiddlewareA, MiddlewareC, MiddlewareB]

    agent do
      name "interleaved_agent"
    end
  end

  test "user-chosen order is preserved verbatim" do
    assert [{MiddlewareA, _}, {MiddlewareC, _}, {MiddlewareB, _}] =
             Jido.Dsl.Agent.Info.middleware(InterleavedAgent)
  end
end
