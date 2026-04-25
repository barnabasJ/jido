defmodule JidoTest.AgentServer.SignalRouterTest do
  use ExUnit.Case, async: true

  alias Jido.AgentServer.SignalRouter
  alias Jido.AgentServer.State
  alias Jido.AgentServer.State.Lifecycle
  alias Jido.Signal.Router, as: JidoRouter

  defmodule TestAction do
    @moduledoc false
    use Jido.Action,
      name: "test_action",
      schema: []

    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}}
  end

  defmodule AnotherAction do
    @moduledoc false
    use Jido.Action,
      name: "another_action",
      schema: []

    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}}
  end

  defmodule PluginWithRoutes do
    @moduledoc false
    use Jido.Plugin,
      name: "plugin_with_routes",
      path: :router_plugin,
      actions: [JidoTest.AgentServer.SignalRouterTest.TestAction],
      signal_routes: [
        {"plugin.custom", JidoTest.AgentServer.SignalRouterTest.TestAction},
        {"plugin.priority", JidoTest.AgentServer.SignalRouterTest.TestAction, -20}
      ]
  end

  defmodule PluginWithoutRoutes do
    @moduledoc false
    use Jido.Plugin,
      name: "plugin_without_routes",
      path: :no_route_plugin,
      actions: [JidoTest.AgentServer.SignalRouterTest.TestAction]
  end

  defmodule AgentWithRoutes do
    @moduledoc false
    use Jido.Agent,
      name: "agent_with_routes",
      path: :domain,
      schema: []

    def signal_routes(_ctx) do
      [
        {"agent.action", JidoTest.AgentServer.SignalRouterTest.TestAction},
        {"agent.priority", JidoTest.AgentServer.SignalRouterTest.TestAction, 10}
      ]
    end
  end

  defmodule AgentWithConfiguredRoutes do
    @moduledoc false
    use Jido.Agent,
      name: "agent_with_configured_routes",
      path: :domain,
      schema: [],
      signal_routes: [{"agent.configured", JidoTest.AgentServer.SignalRouterTest.TestAction}]
  end

  defmodule AgentWithoutRoutes do
    @moduledoc "Agent that does NOT export signal_routes/1"
    use Jido.Agent,
      name: "agent_without_routes",
      path: :domain,
      schema: []
  end

  defmodule AgentWithPlugins do
    @moduledoc false
    use Jido.Agent,
      name: "agent_with_plugins",
      path: :domain,
      schema: [],
      plugins: [PluginWithRoutes, PluginWithoutRoutes]
  end

  defp build_state(agent_module) do
    {:ok, lifecycle} = Lifecycle.new([])

    %State{
      id: "router-test-#{System.unique_integer([:positive])}",
      agent_module: agent_module,
      agent: agent_module.new(),
      status: :idle,
      parent: nil,
      orphaned_from: nil,
      children: %{},
      on_parent_death: :stop,
      jido: Jido,
      partition: nil,
      default_dispatch: nil,
      middleware_chain: nil,
      registry: Jido.Registry,
      spawn_fun: nil,
      cron_jobs: %{},
      cron_monitors: %{},
      cron_monitor_refs: %{},
      cron_restart_attempts: %{},
      cron_restart_timers: %{},
      cron_restart_timer_refs: %{},
      cron_specs: %{},
      cron_runtime_specs: %{},
      skip_schedules: false,
      error_count: 0,
      metrics: %{},
      pending_acks: %{},
      signal_subscribers: %{},
      ready_waiters: %{},
      lifecycle: lifecycle,
      debug: false,
      debug_events: [],
      debug_max_events: 500
    }
  end

  describe "build/1 — agent routes" do
    test "collects routes declared via use Jido.Agent, signal_routes:" do
      router = SignalRouter.build(build_state(AgentWithConfiguredRoutes))
      assert {:ok, [TestAction]} = JidoRouter.route(router, signal("agent.configured"))
    end

    test "collects routes from agent_module.signal_routes/1" do
      router = SignalRouter.build(build_state(AgentWithRoutes))
      assert {:ok, [TestAction]} = JidoRouter.route(router, signal("agent.action"))
      assert {:ok, [TestAction]} = JidoRouter.route(router, signal("agent.priority"))
    end

    test "agent without routes still produces a working router" do
      router = SignalRouter.build(build_state(AgentWithoutRoutes))
      assert {:error, _} = JidoRouter.route(router, signal("nonexistent"))
    end
  end

  describe "build/1 — plugin routes" do
    test "collects routes from plugins, prefixed by the plugin's route prefix" do
      router = SignalRouter.build(build_state(AgentWithPlugins))
      # Plugin name is "plugin_with_routes" so the route gets prefixed.
      assert {:ok, [TestAction]} =
               JidoRouter.route(router, signal("plugin_with_routes.plugin.custom"))

      assert {:ok, [TestAction]} =
               JidoRouter.route(router, signal("plugin_with_routes.plugin.priority"))
    end

    test "plugins without signal_routes contribute nothing" do
      router = SignalRouter.build(build_state(AgentWithPlugins))
      assert {:error, _} = JidoRouter.route(router, signal("no.match"))
    end
  end

  describe "build/1 — built-in routes" do
    test "every agent has the jido.agent.query.children built-in route" do
      router = SignalRouter.build(build_state(AgentWithoutRoutes))

      assert {:ok, [Jido.AgentServer.Actions.QueryChildren]} =
               JidoRouter.route(router, signal("jido.agent.query.children"))
    end
  end

  defp signal(type) do
    {:ok, sig} = Jido.Signal.new(%{type: type, source: "/test", data: %{}})
    sig
  end
end
