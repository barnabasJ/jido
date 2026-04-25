defmodule JidoTest.Actions.ControlTest do
  use ExUnit.Case, async: true

  alias Jido.Actions.Control
  alias Jido.Agent.Directive
  alias Jido.Signal

  defp sig(type, data \\ %{}) do
    Signal.new!(%{type: type, source: "/test", data: data})
  end

  describe "Cancel" do
    test "sets status to failed with cancelled error" do
      {:ok, result, []} = Control.Cancel.run(sig("cancel", %{reason: :cancelled}), %{}, %{}, %{})
      assert result == %{status: :failed, error: {:cancelled, :cancelled}}
    end

    test "includes custom cancellation reason" do
      {:ok, result, []} =
        Control.Cancel.run(sig("cancel", %{reason: :user_requested}), %{}, %{}, %{})

      assert result == %{status: :failed, error: {:cancelled, :user_requested}}
    end
  end

  describe "Noop" do
    test "returns empty state change" do
      {:ok, result, []} = Control.Noop.run(sig("noop"), %{}, %{}, %{})
      assert result == %{}
    end
  end

  describe "Forward" do
    test "creates emit directive to target pid" do
      target = self()
      data = %{target_pid: target, signal_type: nil, payload: nil, source: nil}

      {:ok, result, [directive]} = Control.Forward.run(sig("forward", data), %{}, %{}, %{})

      assert result == %{forwarded_to: target}
      assert %Directive.Emit{} = directive
      assert {:pid, opts} = directive.dispatch
      assert Keyword.get(opts, :target) == target
    end

    test "uses custom signal type when provided" do
      target = self()

      data = %{
        target_pid: target,
        signal_type: "custom.signal",
        payload: nil,
        source: nil
      }

      {:ok, _result, [directive]} = Control.Forward.run(sig("forward", data), %{}, %{}, %{})
      assert directive.signal.type == "custom.signal"
    end

    test "uses custom payload when provided" do
      target = self()

      data = %{
        target_pid: target,
        signal_type: "test",
        payload: %{key: "value"},
        source: nil
      }

      {:ok, _result, [directive]} = Control.Forward.run(sig("forward", data), %{}, %{}, %{})
      assert directive.signal.data == %{key: "value"}
    end
  end

  describe "Broadcast" do
    test "creates emit directive with pubsub dispatch" do
      data = %{
        topic: "workers",
        signal_type: "work.available",
        payload: %{},
        source: "/broadcast"
      }

      {:ok, result, [directive]} = Control.Broadcast.run(sig("broadcast", data), %{}, %{}, %{})

      assert result == %{broadcast_to: "workers"}
      assert %Directive.Emit{} = directive
      assert directive.dispatch == {:pubsub, topic: "workers"}
      assert directive.signal.type == "work.available"
    end
  end

  describe "Reply" do
    test "replies to signal with reply_to pid" do
      reply_pid = self()

      input =
        Signal.new!(%{
          type: "query",
          source: "/test",
          data: %{
            signal_type: "response",
            payload: %{answer: 42},
            reply_to: reply_pid
          }
        })

      {:ok, result, [directive]} = Control.Reply.run(input, %{}, %{}, %{})

      assert result == %{replied_to: reply_pid}
      assert %Directive.Emit{} = directive
      assert directive.signal.type == "response"
      assert directive.signal.data == %{answer: 42}
    end

    test "returns warning when no reply_to found" do
      input =
        Signal.new!(%{
          type: "query",
          source: "/test",
          data: %{signal_type: "response", payload: %{}}
        })

      {:ok, result, []} = Control.Reply.run(input, %{}, %{}, %{})
      assert result == %{replied_to: nil, warning: "No reply_to found in signal"}
    end

    test "returns warning when reply_to is missing on the input signal" do
      input =
        Signal.new!(%{
          type: "query",
          source: "/test",
          data: %{signal_type: "response", payload: %{}}
        })

      {:ok, result, []} = Control.Reply.run(input, %{}, %{}, %{})
      assert result == %{replied_to: nil, warning: "No reply_to found in signal"}
    end
  end
end
