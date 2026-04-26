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
      next = fn _sig, ctx -> {:ok, ctx, []} end
      sig = %Jido.Signal{type: "x", source: "/test", id: "1"}

      assert {:ok, %{} = ctx, []} = PassThrough.on_signal(sig, %{}, %{}, next)
      assert ctx == %{}
    end

    test "opts are passed verbatim and let middleware close over per-registration data" do
      next = fn _sig, ctx -> {:ok, ctx, []} end
      sig = %Jido.Signal{type: "x", source: "/test", id: "1"}

      {:ok, ctx, _} = Tagging.on_signal(sig, %{}, %{tag: :hot}, next)
      assert ctx.tag == :hot

      {:ok, ctx, _} = Tagging.on_signal(sig, %{}, %{tag: :cold}, next)
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

        case next.(signal, ctx) do
          {:ok, ctx, dirs} ->
            {:ok, Map.update!(ctx, :order, &(&1 ++ [:outer_after])), dirs}

          {:error, ctx, reason} ->
            {:error, Map.update!(ctx, :order, &(&1 ++ [:outer_after])), reason}
        end
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
      base = fn _sig, ctx -> {:ok, ctx, []} end
      chain_inner = fn s, c -> Inner.on_signal(s, c, %{}, base) end
      chain_outer = fn s, c -> Outer.on_signal(s, c, %{}, chain_inner) end

      {:ok, ctx, _} = chain_outer.(sig, %{order: []})

      # outside-in: outer enters first, inner second, then unwinds outer
      assert ctx.order == [:outer, :inner, :outer_after]
    end
  end

  describe "tagged-tuple chain semantics (ADR 0018)" do
    defmodule Swallow do
      @moduledoc false
      use Jido.Middleware

      # Catches `{:error, ctx, _}` from `next` and converts it to a
      # success with no directives, so callers see the success-path
      # selector run. ctx flows through either branch.
      @impl true
      def on_signal(signal, ctx, _opts, next) do
        case next.(signal, ctx) do
          {:error, ctx, _reason} -> {:ok, ctx, []}
          ok -> ok
        end
      end
    end

    test "middleware that swallows {:error, _, _} returns {:ok, ctx, []}" do
      sig = %Jido.Signal{type: "x", source: "/test", id: "1"}

      base = fn _sig, ctx -> {:error, ctx, :boom} end
      chain = fn s, c -> Swallow.on_signal(s, c, %{}, base) end

      assert {:ok, %{}, []} = chain.(sig, %{})
    end
  end
end
