defmodule JidoTest.Middleware.RetryTest do
  use ExUnit.Case, async: true

  alias Jido.Middleware.Retry
  alias Jido.Agent.Directive

  defp signal(type \\ "work.start") do
    {:ok, sig} = Jido.Signal.new(%{type: type, source: "/test", data: %{}})
    sig
  end

  describe "on_signal/4 — happy path" do
    test "passes through when no error directive is returned" do
      next = fn _sig, ctx -> {ctx, [%Directive.Emit{signal: signal("ok")}]} end

      {ctx, dirs} = Retry.on_signal(signal(), %{}, %{max_attempts: 3}, next)

      assert ctx == %{}
      assert length(dirs) == 1
    end
  end

  describe "on_signal/4 — retry until success" do
    test "retries while error appears, returning final non-error result" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if n < 2 do
          {ctx, [%Directive.Error{error: %{reason: :transient}}]}
        else
          {ctx, [%Directive.Emit{signal: signal("done")}]}
        end
      end

      {_ctx, dirs} = Retry.on_signal(signal(), %{}, %{max_attempts: 5}, next)

      # Third attempt should have succeeded; we should see the success path
      assert length(dirs) == 1
      assert hd(dirs).__struct__ == Directive.Emit
      assert :counters.get(counter, 1) == 3
    end
  end

  describe "on_signal/4 — max attempts exceeded" do
    test "returns the final error after max_attempts retries" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        :counters.add(counter, 1, 1)
        {ctx, [%Directive.Error{error: %{reason: :always_fails}}]}
      end

      {_ctx, dirs} = Retry.on_signal(signal(), %{}, %{max_attempts: 3}, next)

      assert :counters.get(counter, 1) == 3
      assert [%Directive.Error{error: %{reason: :always_fails}}] = dirs
    end
  end

  describe "on_signal/4 — pattern filtering" do
    test "skips retry when signal type does not match pattern" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        :counters.add(counter, 1, 1)
        {ctx, [%Directive.Error{error: %{reason: :nope}}]}
      end

      {_ctx, dirs} =
        Retry.on_signal(
          signal("audit.log"),
          %{},
          %{max_attempts: 5, pattern: "work.**"},
          next
        )

      # Pattern excludes "audit.log" — single attempt
      assert :counters.get(counter, 1) == 1
      assert length(dirs) == 1
    end

    test "retries when signal type matches the pattern" do
      counter = :counters.new(1, [])

      next = fn _sig, ctx ->
        :counters.add(counter, 1, 1)
        {ctx, [%Directive.Error{error: %{reason: :transient}}]}
      end

      {_ctx, _dirs} =
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
