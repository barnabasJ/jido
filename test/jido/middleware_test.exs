defmodule JidoTest.MiddlewareTest do
  use ExUnit.Case, async: true

  describe "use Jido.Middleware" do
    defmodule PassThrough do
      @moduledoc false
      use Jido.Middleware

      @impl true
      def on_signal(signal, ctx, _opts, next) do
        next.(signal, ctx)
      end
    end

    defmodule Tagging do
      @moduledoc false
      use Jido.Middleware

      @impl true
      def on_signal(signal, ctx, opts, next) do
        next.(signal, Map.put(ctx, :tag, opts[:tag]))
      end
    end

    test "middleware modules implement the behaviour" do
      assert function_exported?(PassThrough, :on_signal, 4)
      assert function_exported?(Tagging, :on_signal, 4)
    end

    test "behaviour is set" do
      assert Jido.Middleware in PassThrough.module_info()[:attributes][:behaviour]
      assert Jido.Middleware in Tagging.module_info()[:attributes][:behaviour]
    end

    test "callback receives signal, ctx, opts, next" do
      next = fn _sig, ctx -> {ctx, []} end
      sig = %Jido.Signal{type: "x", source: "/test", id: "1"}

      {ctx, dirs} = PassThrough.on_signal(sig, %{}, %{}, next)

      assert ctx == %{}
      assert dirs == []
    end

    test "opts are passed verbatim and let middleware close over per-registration data" do
      next = fn _sig, ctx -> {ctx, []} end
      sig = %Jido.Signal{type: "x", source: "/test", id: "1"}

      {ctx, _} = Tagging.on_signal(sig, %{}, %{tag: :hot}, next)
      assert ctx.tag == :hot

      {ctx, _} = Tagging.on_signal(sig, %{}, %{tag: :cold}, next)
      assert ctx.tag == :cold
    end
  end

  describe "next-passing chain composition" do
    defmodule Outer do
      @moduledoc false
      use Jido.Middleware

      @impl true
      def on_signal(signal, ctx, _opts, next) do
        ctx = Map.update(ctx, :order, [:outer], &(&1 ++ [:outer]))
        {ctx, dirs} = next.(signal, ctx)
        {Map.update!(ctx, :order, &(&1 ++ [:outer_after])), dirs}
      end
    end

    defmodule Inner do
      @moduledoc false
      use Jido.Middleware

      @impl true
      def on_signal(signal, ctx, _opts, next) do
        ctx = Map.update(ctx, :order, [:inner], &(&1 ++ [:inner]))
        next.(signal, ctx)
      end
    end

    test "middleware composes outside-in" do
      sig = %Jido.Signal{type: "x", source: "/test", id: "1"}

      # Build chain manually: Outer wraps Inner, which wraps the no-op base
      base = fn _sig, ctx -> {ctx, []} end
      chain_inner = fn s, c -> Inner.on_signal(s, c, %{}, base) end
      chain_outer = fn s, c -> Outer.on_signal(s, c, %{}, chain_inner) end

      {ctx, _} = chain_outer.(sig, %{order: []})

      # outside-in: outer enters first, inner second, then unwinds outer
      assert ctx.order == [:outer, :inner, :outer_after]
    end
  end
end
