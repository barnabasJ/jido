defmodule JidoTest.AgentServer.LifecycleSignalsTest do
  use JidoTest.Case, async: false

  alias Jido.AgentServer

  defmodule LifecycleAgent do
    @moduledoc false
    use Jido.Agent,
      name: "lifecycle_signals_agent",
      path: :domain,
      schema: []

    def signal_routes(_ctx), do: []
  end

  setup ctx do
    # Subscribe to our own pid for capture
    {:ok, ctx}
  end

  describe "await_ready/2" do
    test "returns :ok after the agent emits jido.agent.lifecycle.ready", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(
          jido: jido,
          agent_module: LifecycleAgent,
          id: "ready-1"
        )

      assert :ok = AgentServer.await_ready(pid, 5_000)
    end

    test "is idempotent — subsequent calls return :ok immediately", %{jido: jido} do
      {:ok, pid} =
        AgentServer.start_link(
          jido: jido,
          agent_module: LifecycleAgent,
          id: "ready-2"
        )

      assert :ok = AgentServer.await_ready(pid, 5_000)
      assert :ok = AgentServer.await_ready(pid, 100)
    end

    test "returns an error tuple for an unresolvable server reference" do
      assert {:error, _} = AgentServer.await_ready("never-started-agent-id", 100)
    end
  end
end
