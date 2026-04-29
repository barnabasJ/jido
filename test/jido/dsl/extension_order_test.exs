defmodule Jido.Dsl.ExtensionOrderTest do
  @moduledoc """
  Verifies that the `extensions: […]` registration order is preserved
  when classifying entries into plugins / slices / middleware. The
  middleware-chain order is significant for the `on_signal/4`
  pipeline, so the test asserts the host's middleware list mirrors
  declaration order.
  """

  use ExUnit.Case, async: true

  alias Jido.Dsl.Agent.Info, as: AgentInfo

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

  defmodule HostOrderTest do
    @moduledoc false
    use Jido.Agent,
      extensions: [MiddlewareA, MiddlewareB, MiddlewareC],
      default_slices: false

    agent do
      name "host_order_test"
    end
  end

  defmodule HostReverseOrder do
    @moduledoc false
    use Jido.Agent,
      extensions: [MiddlewareC, MiddlewareB, MiddlewareA],
      default_slices: false

    agent do
      name "host_reverse_order"
    end
  end

  describe "middleware-chain order preservation" do
    test "middleware list mirrors declaration order" do
      middleware = AgentInfo.middleware(HostOrderTest)
      mods = Enum.map(middleware, fn {mod, _opts} -> mod end)

      assert mods == [MiddlewareA, MiddlewareB, MiddlewareC]
    end

    test "reversing the declaration order reverses the middleware list" do
      middleware = AgentInfo.middleware(HostReverseOrder)
      mods = Enum.map(middleware, fn {mod, _opts} -> mod end)

      assert mods == [MiddlewareC, MiddlewareB, MiddlewareA]
    end
  end
end
