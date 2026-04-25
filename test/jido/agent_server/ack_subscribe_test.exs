defmodule JidoTest.AgentServer.AckSubscribeTest do
  use JidoTest.Case, async: false

  alias Jido.AgentServer

  defmodule WriteAction do
    @moduledoc false
    use Jido.Action, name: "write", path: :app, schema: []

    def run(%Jido.Signal{data: %{value: v}}, slice, _opts, _ctx) do
      {:ok, %{slice | value: v, status: :written}}
    end
  end

  defmodule TestAgent do
    @moduledoc false
    use Jido.Agent,
      name: "ack_subscribe_agent",
      path: :app,
      schema: [
        value: [type: :integer, default: 0],
        status: [type: :atom, default: :idle]
      ]

    def signal_routes(_ctx) do
      [{"write", JidoTest.AgentServer.AckSubscribeTest.WriteAction}]
    end
  end


  describe "cast_and_await/4" do
    test "fires the selector after the signal completes and returns its value", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.cast_and_await(
          pid,
          signal("write", %{value: 7}),
          fn %AgentServer.State{agent: agent} ->
            case agent.state.app.status do
              :written -> {:ok, agent.state.app.value}
              _ -> {:error, :not_yet}
            end
          end,
          timeout: 5_000
        )

      assert {:ok, 7} = result
    end

    test "returns {:error, reason} when the selector returns an error tuple", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.cast_and_await(
          pid,
          signal("write", %{value: 1}),
          fn _state -> {:error, :selector_says_no} end,
          timeout: 1_000
        )

      assert {:error, :selector_says_no} = result
    end

    test "returns {:error, :timeout} when the agent never produces an ack", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.cast_and_await(
          pid,
          signal("does.not.match.any.route"),
          fn _state -> :skip end,
          timeout: 100
        )

      # The signal still produces an ack (default route fires); selector is required to
      # return either {:ok, _} or {:error, _}. With :skip it loops; we hit timeout.
      assert {:error, :timeout} = result
    end
  end

  describe "subscribe/4" do
    test "delivers a result on the first matching signal when once: true", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, ref} =
        AgentServer.subscribe(
          pid,
          "write",
          fn %AgentServer.State{agent: agent} ->
            {:ok, agent.state.app.value}
          end,
          once: true
        )

      :ok = AgentServer.cast(pid, signal("write", %{value: 42}))

      assert_receive {:jido_subscription, ^ref, %{result: {:ok, 42}}}, 5_000
    end

    test "with :skip return, keeps the subscription alive across multiple signals", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      caller = self()

      {:ok, ref} =
        AgentServer.subscribe(
          pid,
          "write",
          fn %AgentServer.State{agent: agent} ->
            send(caller, {:saw_value, agent.state.app.value})
            :skip
          end,
          []
        )

      :ok = AgentServer.cast(pid, signal("write", %{value: 1}))
      :ok = AgentServer.cast(pid, signal("write", %{value: 2}))

      assert_receive {:saw_value, 1}, 5_000
      assert_receive {:saw_value, 2}, 5_000

      :ok = AgentServer.unsubscribe(pid, ref)
    end

    test "unsubscribe/2 stops the subscription", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, ref} =
        AgentServer.subscribe(pid, "write", fn _s -> {:ok, :received} end, [])

      :ok = AgentServer.unsubscribe(pid, ref)
      :ok = AgentServer.cast(pid, signal("write", %{value: 99}))

      refute_receive {:jido_subscription, ^ref, _}, 200
    end

    test "ignores signals that don't match the pattern", %{jido: jido} do
      pid = start_server(%{jido: jido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, ref} =
        AgentServer.subscribe(pid, "specific.path", fn _ -> {:ok, :hit} end, once: true)

      :ok = AgentServer.cast(pid, signal("write", %{value: 1}))

      refute_receive {:jido_subscription, ^ref, _}, 200
      :ok = AgentServer.unsubscribe(pid, ref)
    end
  end
end
