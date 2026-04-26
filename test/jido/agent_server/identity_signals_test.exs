defmodule JidoTest.AgentServer.IdentitySignalsTest do
  use JidoTest.Case, async: false

  alias Jido.AgentServer

  defmodule WatcherAction do
    @moduledoc false
    use Jido.Action, name: "identity_watcher", path: :app, schema: []

    def run(%Jido.Signal{type: type, data: data}, slice, _opts, _ctx) do
      events = Map.get(slice, :identity_events, [])
      {:ok, %{slice | identity_events: events ++ [%{type: type, data: data}]}, []}
    end
  end

  defmodule WatcherAgent do
    @moduledoc false
    use Jido.Agent,
      name: "identity_signals_agent",
      path: :app,
      schema: [
        identity_events: [type: {:list, :any}, default: []]
      ]

    def signal_routes(_ctx) do
      [
        {"jido.agent.identity.partition_assigned",
         JidoTest.AgentServer.IdentitySignalsTest.WatcherAction}
      ]
    end
  end

  describe "partition_assigned signal" do
    test "emits at startup with the configured partition", %{jido: jido} do
      pid =
        start_server(%{jido: jido}, WatcherAgent,
          id: "identity-1",
          partition: :work_partition
        )

      :ok = AgentServer.await_ready(pid)

      {:ok, events} =
        AgentServer.state(pid, fn s -> {:ok, s.agent.state.app.identity_events} end)

      assert Enum.any?(events, fn e ->
               e.type == "jido.agent.identity.partition_assigned" and
                 e.data[:partition] == :work_partition
             end)
    end

    test "emits with nil partition when none is set", %{jido: jido} do
      pid = start_server(%{jido: jido}, WatcherAgent, id: "identity-2")
      :ok = AgentServer.await_ready(pid)

      {:ok, events} =
        AgentServer.state(pid, fn s -> {:ok, s.agent.state.app.identity_events} end)

      assert Enum.any?(events, fn e ->
               e.type == "jido.agent.identity.partition_assigned" and
                 e.data[:partition] == nil
             end)
    end
  end
end
