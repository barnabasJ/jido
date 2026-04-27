defmodule JidoTest.Middleware.RetryTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Middleware.Retry

  defp signal(type \\ "work.start") do
    {:ok, sig} = Jido.Signal.new(%{type: type, source: "/test", data: %{}})
    sig
  end

  describe "on_signal/4 — happy path" do
    test "passes the chain success through verbatim" do
      next = fn _sig, ctx -> {:ok, ctx, [%Directive.Emit{signal: signal("ok")}]} end

      assert {:ok, %{} = _ctx, dirs} =
               Retry.on_signal(signal(), %{}, %{max_attempts: 3}, next)

      assert length(dirs) == 1
    end

    test "user-emitted %Error{} on the success path does NOT trigger retry" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        :counters.add(counter, 1, 1)

        # Action emits an %Error{} directive on the success path for log/audit;
        # the chain itself returned {:ok, _, _}. Retry must not fire here.
        {:ok, ctx, [%Directive.Error{error: %{reason: :logged_for_audit}}]}
      end

      assert {:ok, _ctx, dirs} =
               Retry.on_signal(signal(), %{}, %{max_attempts: 5}, next)

      # Single attempt; the audit-style error directive is irrelevant to Retry.
      assert :counters.get(counter, 1) == 1
      assert [%Directive.Error{}] = dirs
    end
  end

  describe "on_signal/4 — retry until success" do
    test "retries while the chain returns {:error, _, _}, returning the eventual success" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if n < 2 do
          {:error, ctx, :transient}
        else
          {:ok, ctx, [%Directive.Emit{signal: signal("done")}]}
        end
      end

      assert {:ok, _ctx, dirs} =
               Retry.on_signal(signal(), %{}, %{max_attempts: 5}, next)

      # Third attempt succeeded; observable through the success directive list.
      assert length(dirs) == 1
      assert hd(dirs).__struct__ == Directive.Emit
      assert :counters.get(counter, 1) == 3
    end
  end

  describe "on_signal/4 — max attempts exceeded" do
    test "returns the final {:error, _, _} after max_attempts retries" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        :counters.add(counter, 1, 1)
        {:error, ctx, :always_fails}
      end

      assert {:error, _ctx, :always_fails} =
               Retry.on_signal(signal(), %{}, %{max_attempts: 3}, next)

      assert :counters.get(counter, 1) == 3
    end
  end

  describe "on_signal/4 — pattern filtering" do
    test "skips retry when signal type does not match pattern" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        :counters.add(counter, 1, 1)
        {:error, ctx, :nope}
      end

      assert {:error, _ctx, :nope} =
               Retry.on_signal(
                 signal("audit.log"),
                 %{},
                 %{max_attempts: 5, pattern: "work.**"},
                 next
               )

      # Pattern excludes "audit.log" — single attempt.
      assert :counters.get(counter, 1) == 1
    end

    test "retries when signal type matches the pattern" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        :counters.add(counter, 1, 1)
        {:error, ctx, :transient}
      end

      assert {:error, _ctx, :transient} =
               Retry.on_signal(
                 signal("work.start"),
                 %{},
                 %{max_attempts: 3, pattern: "work.**"},
                 next
               )

      assert :counters.get(counter, 1) == 3
    end
  end
end
