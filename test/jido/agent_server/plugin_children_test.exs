defmodule JidoTest.AgentServer.PluginChildrenTest do
  use JidoTest.Case, async: true

  # Test action
  defmodule SimpleAction do
    @moduledoc false
    use Jido.Action,
      name: "simple_action",
      schema: []

    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}, []}
  end

  # Plugin with no child_spec (default returns nil)
  defmodule NoChildPlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "no_child_plugin",
      path: :no_child,
      actions: [JidoTest.AgentServer.PluginChildrenTest.SimpleAction]
  end

  # Plugin that starts a single Agent as a child
  defmodule SingleChildPlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "single_child_plugin",
      path: :single_child,
      actions: [JidoTest.AgentServer.PluginChildrenTest.SimpleAction]

    def child_spec(config) do
      initial_value = config[:initial_value] || :default

      %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> initial_value end]}
      }
    end
  end

  # Plugin that starts multiple children
  defmodule MultiChildPlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "multi_child_plugin",
      path: :multi_child,
      actions: [JidoTest.AgentServer.PluginChildrenTest.SimpleAction]

    def child_spec(config) do
      count = config[:count] || 2

      Enum.map(1..count, fn i ->
        %{
          id: {__MODULE__, i},
          start: {Agent, :start_link, [fn -> {:worker, i} end]}
        }
      end)
    end
  end

  # Plugin with invalid child_spec (for error handling test)
  defmodule InvalidChildSpecPlugin do
    @moduledoc false
    use Jido.Plugin,
      name: "invalid_child_spec_plugin",
      path: :invalid_child,
      actions: [JidoTest.AgentServer.PluginChildrenTest.SimpleAction]

    def child_spec(_config) do
      :not_a_valid_child_spec
    end
  end

  # Agent with no child plugin
  defmodule NoChildAgent do
    @moduledoc false
    use Jido.Agent,
      name: "no_child_agent",
      path: :domain,
      plugins: [JidoTest.AgentServer.PluginChildrenTest.NoChildPlugin]
  end

  # Agent with single child plugin
  defmodule SingleChildAgent do
    @moduledoc false
    use Jido.Agent,
      name: "single_child_agent",
      path: :domain,
      plugins: [JidoTest.AgentServer.PluginChildrenTest.SingleChildPlugin]
  end

  # Agent with configured child plugin
  defmodule ConfiguredChildAgent do
    @moduledoc false
    use Jido.Agent,
      name: "configured_child_agent",
      path: :domain,
      plugins: [
        {JidoTest.AgentServer.PluginChildrenTest.SingleChildPlugin, %{initial_value: :custom}}
      ]
  end

  # Agent with multi child plugin
  defmodule MultiChildAgent do
    @moduledoc false
    use Jido.Agent,
      name: "multi_child_agent",
      path: :domain,
      plugins: [{JidoTest.AgentServer.PluginChildrenTest.MultiChildPlugin, %{count: 3}}]
  end

  # Agent with invalid child spec plugin
  defmodule InvalidChildAgent do
    @moduledoc false
    use Jido.Agent,
      name: "invalid_child_agent",
      path: :domain,
      plugins: [JidoTest.AgentServer.PluginChildrenTest.InvalidChildSpecPlugin]
  end

  describe "child_spec/1 with no children" do
    test "plugin returning nil starts no children", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: NoChildAgent, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)
      assert children == %{}

      GenServer.stop(pid)
    end
  end

  describe "child_spec/1 with single child" do
    test "plugin starts child process on AgentServer init", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: SingleChildAgent, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      # Should have one child
      assert map_size(children) == 1

      # Get the child info
      [{tag, child_info}] = Map.to_list(children)

      # Tag should be {:plugin, PluginModule, ChildId}
      assert {:plugin, JidoTest.AgentServer.PluginChildrenTest.SingleChildPlugin, _} = tag

      # Child should be alive
      assert Process.alive?(child_info.pid)

      # Child should have the default value
      assert Agent.get(child_info.pid, & &1) == :default

      GenServer.stop(pid)
    end

    test "child receives config from plugin config", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: ConfiguredChildAgent, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      [{_tag, child_info}] = Map.to_list(children)
      assert Agent.get(child_info.pid, & &1) == :custom

      GenServer.stop(pid)
    end

    test "child is monitored by AgentServer", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: SingleChildAgent, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)
      [{_tag, child_info}] = Map.to_list(children)

      # Child has a monitor ref
      assert child_info.ref != nil

      # Manually stop the child
      Agent.stop(child_info.pid)

      # Child should be removed from state
      await_state_value(pid, fn s -> if map_size(s.children) == 0, do: true end)

      GenServer.stop(pid)
    end
  end

  describe "child_spec/1 with multiple children" do
    test "plugin can start multiple child processes", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: MultiChildAgent, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      # Should have 3 children
      assert map_size(children) == 3

      # All children should be alive
      Enum.each(children, fn {_tag, child_info} ->
        assert Process.alive?(child_info.pid)
      end)

      GenServer.stop(pid)
    end
  end

  describe "child_spec/1 error handling" do
    test "invalid child_spec is logged but doesn't crash server", %{jido: jido} do
      # This should start successfully but log a warning
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: InvalidChildAgent, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)
      # No children should be started due to invalid spec
      assert children == %{}

      GenServer.stop(pid)
    end
  end

  describe "child cleanup on AgentServer stop" do
    test "children are cleaned up when AgentServer stops", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: SingleChildAgent, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)
      [{_tag, child_info}] = Map.to_list(children)
      child_pid = child_info.pid

      assert Process.alive?(child_pid)

      # Stop the AgentServer
      GenServer.stop(pid)

      eventually(fn -> not Process.alive?(pid) end)
    end
  end
end
