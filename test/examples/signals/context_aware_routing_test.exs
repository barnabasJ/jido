defmodule JidoExampleTest.ContextAwareRoutingTest do
  @moduledoc """
  Example test demonstrating dynamic signal routes via the context parameter in signal_routes/1.

  This test shows:
  - signal_routes/1 receives a context map (not signal_routes/0)
  - Context contains agent module info that can be used for dynamic routing
  - Actions can inspect agent state to gate behavior by mode
  - Multiple route configurations driven by agent design

  Run with: mix test --include example
  """
  use JidoTest.Case, async: false

  @moduletag :example
  @moduletag timeout: 15_000

  alias Jido.AgentServer

  # ===========================================================================
  # ACTIONS: Mode-aware processing
  # ===========================================================================

  defmodule ProcessAction do
    @moduledoc false
    use Jido.Action,
      name: "process",
      schema: [
        value: [type: :integer, default: 1]
      ]

    def run(%Jido.Signal{data: %{value: value}}, slice, _opts, _ctx) do
      current = Map.get(slice, :counter, 0)
      {:ok, %{counter: current + value, message: "processed"}, []}
    end
  end

  defmodule MaintenanceAction do
    @moduledoc false
    use Jido.Action,
      name: "maintenance_handler",
      schema: [
        value: [type: :integer, default: 0]
      ]

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{message: "system in maintenance mode"}, []}
    end
  end

  defmodule SetModeAction do
    @moduledoc false
    use Jido.Action,
      name: "set_mode",
      schema: [
        mode: [type: :atom, required: true]
      ]

    def run(%Jido.Signal{data: %{mode: mode}}, _slice, _opts, _ctx) do
      {:ok, %{mode: mode}, []}
    end
  end

  defmodule AdminAction do
    @moduledoc false
    use Jido.Action,
      name: "admin_action",
      schema: [
        command: [type: :string, required: true]
      ]

    def run(%Jido.Signal{data: %{command: command}}, slice, _opts, _ctx) do
      log = Map.get(slice, :admin_log, [])
      {:ok, %{admin_log: [command | log], message: "admin: #{command}"}, []}
    end
  end

  # ===========================================================================
  # AGENTS: Different routing strategies based on context
  # ===========================================================================

  defmodule GatedAgent do
    @moduledoc false
    use Jido.Agent,
      name: "gated_agent",
      path: :domain,
      schema: [
        mode: [type: :atom, default: :normal],
        counter: [type: :integer, default: 0],
        message: [type: :string, default: nil],
        admin_log: [type: {:list, :string}, default: []]
      ]

    def signal_routes(ctx) do
      base_routes = [
        {"set_mode", SetModeAction},
        {"admin", AdminAction}
      ]

      process_route =
        case ctx do
          %{maintenance: true} ->
            {"process", MaintenanceAction}

          _ ->
            {"process", ProcessAction}
        end

      [process_route | base_routes]
    end
  end

  defmodule MinimalAgent do
    @moduledoc false
    use Jido.Agent,
      name: "minimal_agent",
      path: :domain,
      schema: [
        counter: [type: :integer, default: 0]
      ]

    def signal_routes(ctx) do
      [{"process", ProcessAction, 5}] ++
        if Map.get(ctx, :agent_module) == __MODULE__ do
          [{"self_check", ProcessAction}]
        else
          []
        end
    end
  end

  # ===========================================================================
  # TESTS
  # ===========================================================================

  describe "signal_routes/1 receives context" do
    test "signal_routes/1 is called with a context map", %{jido: _jido} do
      ctx = %{agent_module: GatedAgent}
      routes = GatedAgent.signal_routes(ctx)

      assert is_list(routes)
      assert routes != []

      route_paths = Enum.map(routes, fn route -> elem(route, 0) end)
      assert "process" in route_paths
      assert "set_mode" in route_paths
    end

    test "context includes agent_module key", %{jido: _jido} do
      ctx = %{agent_module: MinimalAgent}
      routes = MinimalAgent.signal_routes(ctx)

      route_paths = Enum.map(routes, fn route -> elem(route, 0) end)
      assert "process" in route_paths
      assert "self_check" in route_paths
    end
  end

  describe "routes vary based on context values" do
    test "default context routes process to ProcessAction" do
      routes = GatedAgent.signal_routes(%{})

      process_route = Enum.find(routes, fn route -> elem(route, 0) == "process" end)
      assert elem(process_route, 1) == ProcessAction
    end

    test "maintenance context routes process to MaintenanceAction" do
      routes = GatedAgent.signal_routes(%{maintenance: true})

      process_route = Enum.find(routes, fn route -> elem(route, 0) == "process" end)
      assert elem(process_route, 1) == MaintenanceAction
    end

    test "non-maintenance routes remain unchanged across contexts" do
      normal_routes = GatedAgent.signal_routes(%{})
      maint_routes = GatedAgent.signal_routes(%{maintenance: true})

      normal_set_mode = Enum.find(normal_routes, fn r -> elem(r, 0) == "set_mode" end)
      maint_set_mode = Enum.find(maint_routes, fn r -> elem(r, 0) == "set_mode" end)

      assert normal_set_mode == maint_set_mode
    end
  end

  describe "multiple signal types with context-aware routing" do
    test "all expected routes are present", %{jido: _jido} do
      routes = GatedAgent.signal_routes(%{agent_module: GatedAgent})

      route_paths = Enum.map(routes, fn route -> elem(route, 0) end)
      assert "process" in route_paths
      assert "set_mode" in route_paths
      assert "admin" in route_paths
    end

    test "routes support priority tuples" do
      routes = MinimalAgent.signal_routes(%{agent_module: MinimalAgent})

      process_route = Enum.find(routes, fn route -> elem(route, 0) == "process" end)
      assert tuple_size(process_route) == 3
      assert elem(process_route, 2) == 5
    end
  end

  describe "agent processes signals through context-aware routes" do
    test "normal mode processes signals with ProcessAction", %{jido: jido} do
      {:ok, pid} = Jido.start_agent(jido, GatedAgent, id: unique_id("gated"))

      signal = signal("process", %{value: 10})
      {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert agent.state.domain.counter == 10
      assert agent.state.domain.message == "processed"
    end

    test "set_mode changes agent state", %{jido: jido} do
      {:ok, pid} = Jido.start_agent(jido, GatedAgent, id: unique_id("gated"))

      {:ok, agent} =
        AgentServer.call(pid, signal("set_mode", %{mode: :maintenance}), fn s ->
          {:ok, s.agent}
        end)

      assert agent.state.domain.mode == :maintenance

      {:ok, agent} =
        AgentServer.call(pid, signal("set_mode", %{mode: :admin}), fn s -> {:ok, s.agent} end)

      assert agent.state.domain.mode == :admin
    end

    test "admin action records commands", %{jido: jido} do
      {:ok, pid} = Jido.start_agent(jido, GatedAgent, id: unique_id("gated"))

      {:ok, _} =
        AgentServer.call(pid, signal("admin", %{command: "flush_cache"}), fn s ->
          {:ok, s.agent}
        end)

      {:ok, agent} =
        AgentServer.call(pid, signal("admin", %{command: "restart_workers"}), fn s ->
          {:ok, s.agent}
        end)

      assert length(agent.state.domain.admin_log) == 2
      assert "restart_workers" in agent.state.domain.admin_log
      assert "flush_cache" in agent.state.domain.admin_log
    end

    test "sequential signals accumulate state correctly", %{jido: jido} do
      {:ok, pid} = Jido.start_agent(jido, GatedAgent, id: unique_id("gated"))

      {:ok, _} = AgentServer.call(pid, signal("process", %{value: 5}), fn s -> {:ok, s.agent} end)

      {:ok, _} =
        AgentServer.call(pid, signal("set_mode", %{mode: :admin}), fn s -> {:ok, s.agent} end)

      {:ok, _} =
        AgentServer.call(pid, signal("admin", %{command: "check_status"}), fn s ->
          {:ok, s.agent}
        end)

      {:ok, _} = AgentServer.call(pid, signal("process", %{value: 3}), fn s -> {:ok, s.agent} end)

      {:ok, %{counter: counter, mode: mode, admin_log_length: admin_log_length}} =
        AgentServer.state(pid, fn s ->
          {:ok,
           %{
             counter: s.agent.state.domain.counter,
             mode: s.agent.state.domain.mode,
             admin_log_length: length(s.agent.state.domain.admin_log)
           }}
        end)

      assert counter == 8
      assert mode == :admin
      assert admin_log_length == 1
    end
  end
end
