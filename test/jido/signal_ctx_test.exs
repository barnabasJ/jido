defmodule JidoTest.SignalCtxTest do
  @moduledoc """
  Tests for `Jido.SignalCtx` helpers and end-to-end ctx delivery into the
  action's `run/4` callback via `Jido.Exec.run/*`.
  """

  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.SignalCtx

  describe "put/3 + get/3 + ctx/1" do
    test "writes and reads a single key" do
      {:ok, sig} = Signal.new("t.x", %{}, source: "/x")
      sig = SignalCtx.put(sig, :trace_id, "t-1")
      assert SignalCtx.get(sig, :trace_id) == "t-1"
      assert SignalCtx.ctx(sig) == %{trace_id: "t-1"}
    end

    test "default for missing key" do
      {:ok, sig} = Signal.new("t.x", %{}, source: "/x")
      assert SignalCtx.get(sig, :missing) == nil
      assert SignalCtx.get(sig, :missing, :fallback) == :fallback
    end

    test "merge/2 combines into existing ctx (right-biased)" do
      {:ok, sig} = Signal.new("t.x", %{}, source: "/x")

      sig =
        sig
        |> SignalCtx.put(:trace_id, "t-1")
        |> SignalCtx.merge(%{trace_id: "t-2", user: "u"})

      assert SignalCtx.get(sig, :trace_id) == "t-2"
      assert SignalCtx.get(sig, :user) == "u"
    end

    test "delete/2 removes a key" do
      {:ok, sig} = Signal.new("t.x", %{}, source: "/x")

      sig =
        sig
        |> SignalCtx.put(:trace_id, "t-1")
        |> SignalCtx.put(:tenant, "acme")
        |> SignalCtx.delete(:tenant)

      assert SignalCtx.ctx(sig) == %{trace_id: "t-1"}
    end

    test "inherit/2 copies source ctx into target without overwriting target keys" do
      {:ok, src} = Signal.new("a", %{}, source: "/a")
      src = SignalCtx.merge(src, %{trace_id: "src", user: "u"})

      {:ok, dst} = Signal.new("b", %{}, source: "/b")
      dst = SignalCtx.put(dst, :trace_id, "dst")

      merged = SignalCtx.inherit(dst, src)
      assert SignalCtx.get(merged, :trace_id) == "dst"
      assert SignalCtx.get(merged, :user) == "u"
    end
  end

  describe "ctx delivery into action.run/4" do
    defmodule TraceProbe do
      @moduledoc false
      use Jido.Action, name: "trace_probe", schema: []

      @impl true
      def run(_signal, _slice, _opts, ctx) do
        {:ok, %{trace_id: Map.get(ctx, :trace_id), user: Map.get(ctx, :user)}}
      end
    end

    test "Jido.Exec.run delivers signal ctx to the action's ctx arg" do
      {:ok, sig} = Signal.new("trace_probe", %{}, source: "/test")

      sig =
        sig
        |> SignalCtx.put(:trace_id, "abc-123")
        |> SignalCtx.put(:user, "alice")

      assert {:ok, %{trace_id: "abc-123", user: "alice"}} =
               Jido.Exec.run(TraceProbe, %{}, %{signal: sig})
    end

    test "without an explicit signal, ctx defaults to %{}" do
      assert {:ok, %{trace_id: nil, user: nil}} =
               Jido.Exec.run(TraceProbe, %{}, %{})
    end
  end
end
