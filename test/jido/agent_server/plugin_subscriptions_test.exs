defmodule JidoTest.AgentServer.PluginSubscriptionsTest do
  use JidoTest.Case, async: false

  alias Jido.Sensor.Runtime

  @moduletag :capture_log

  # ---------------------------------------------------------------------------
  # Test Sensor Module
  # ---------------------------------------------------------------------------

  defmodule TestSensor do
    @moduledoc false
    use Jido.Sensor

    sensor do
      name "test_sensor"
      description "A sensor for testing plugin subscriptions"

      schema(
        Zoi.object(
          %{
            emit_on_init: Zoi.boolean() |> Zoi.default(false),
            signal_type: Zoi.string() |> Zoi.default("test.sensor.event")
          },
          coerce: true
        )
      )
    end

    @impl Jido.Sensor
    def init(config, context) do
      state = %{
        config: config,
        context: context,
        event_count: 0
      }

      if config.emit_on_init do
        signal =
          Jido.Signal.new!(%{
            source: "/sensor/test",
            type: config.signal_type,
            data: %{event: :initialized, context_keys: Map.keys(context)}
          })

        {:ok, state, [{:emit, signal}]}
      else
        {:ok, state}
      end
    end

    @impl Jido.Sensor
    def handle_event({:trigger, value}, state) do
      signal =
        Jido.Signal.new!(%{
          source: "/sensor/test",
          type: state.config.signal_type,
          data: %{value: value, count: state.event_count + 1}
        })

      new_state = %{state | event_count: state.event_count + 1}
      {:ok, new_state, [{:emit, signal}]}
    end

    def handle_event(_event, state) do
      {:ok, state}
    end
  end

  defmodule SecondTestSensor do
    @moduledoc false
    use Jido.Sensor

    sensor do
      name "second_test_sensor"
      description "A second sensor for multi-sensor tests"

      schema(
        Zoi.object(%{sensor_id: Zoi.string() |> Zoi.default("second")},
          coerce: true
        )
      )
    end

    @impl Jido.Sensor
    def init(config, context) do
      signal =
        Jido.Signal.new!(%{
          source: "/sensor/#{config.sensor_id}",
          type: "second.sensor.init",
          data: %{sensor_id: config.sensor_id, agent_id: context.agent_id}
        })

      {:ok, %{config: config, context: context}, [{:emit, signal}]}
    end

    @impl Jido.Sensor
    def handle_event(_event, state) do
      {:ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Test Action Module
  # ---------------------------------------------------------------------------

  defmodule SimpleAction do
    @moduledoc false
    use Jido.Action

    action do
      name "simple_action"
      schema []
    end

    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}, []}
  end

  defmodule RecordSensorSignalAction do
    @moduledoc false
    use Jido.Action

    action do
      name "record_sensor_signal"
      schema value: [type: :any, required: true], count: [type: :integer, required: true]
    end

    def run(%Jido.Signal{data: params}, _slice, _opts, _ctx) do
      {:ok, %{last_sensor_value: params.value, last_sensor_count: params.count}, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Test Plugin Modules
  # ---------------------------------------------------------------------------

  defmodule PluginWithSensor do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_with_sensor"
    end

    def subscriptions(_config, context) do
      [
        {JidoTest.AgentServer.PluginSubscriptionsTest.TestSensor,
         %{emit_on_init: true, signal_type: "plugin.sensor.ready", agent_ref: context.agent_ref}}
      ]
    end
  end

  defmodule PluginWithMultipleSensors do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_with_multiple_sensors"
    end

    def subscriptions(_config, context) do
      [
        {JidoTest.AgentServer.PluginSubscriptionsTest.TestSensor,
         %{emit_on_init: true, signal_type: "first.sensor.event", agent_ref: context.agent_ref}},
        {JidoTest.AgentServer.PluginSubscriptionsTest.SecondTestSensor,
         %{sensor_id: "multi-test", agent_ref: context.agent_ref}}
      ]
    end
  end

  defmodule PluginWithNoSubscriptions do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_with_no_subscriptions"
    end

    def subscriptions(_config, _context) do
      []
    end
  end

  defmodule PluginWithoutSubscriptionsCallback do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_without_subscriptions_callback"
    end
  end

  defmodule PluginWithRoutedSensor do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_with_routed_sensor"
    end

    def subscriptions(_config, context) do
      [
        {JidoTest.AgentServer.PluginSubscriptionsTest.TestSensor,
         %{
           emit_on_init: false,
           signal_type: "plugin.sensor.delivered",
           agent_ref: context.agent_ref
         }}
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # Test Agent Modules
  # ---------------------------------------------------------------------------

  defmodule AgentWithSensorPlugin do
    @moduledoc false
    use Jido.Agent,
      middleware: [JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithSensor]

    agent do
      name "agent_with_sensor_plugin"
    end

    slices do
      slice(:with_sensor, JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithSensor)
    end
  end

  defmodule AgentWithRoutedSensorPlugin do
    @moduledoc false
    use Jido.Agent,
      middleware: [JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithRoutedSensor]

    agent do
      name "agent_with_routed_sensor_plugin"
      path :domain

      schema last_sensor_value: [type: :any, default: nil],
             last_sensor_count: [type: :integer, default: 0]
    end

    slices do
      slice(:routed_sensor, JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithRoutedSensor)
    end

    signal_routes do
      route "plugin.sensor.delivered",
            JidoTest.AgentServer.PluginSubscriptionsTest.RecordSensorSignalAction
    end
  end

  defmodule PluginWithStaticSubscriptions do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_with_static_subscriptions"
    end

    subscriptions do
      subscription JidoTest.AgentServer.PluginSubscriptionsTest.TestSensor,
                   %{emit_on_init: true, signal_type: "static.sensor.ready"}
    end
  end

  defmodule AgentWithStaticSubscriptionPlugin do
    @moduledoc false
    use Jido.Agent,
      middleware: [JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithStaticSubscriptions]

    agent do
      name "agent_with_static_sub_plugin"
    end

    slices do
      slice(
        :static_subs,
        JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithStaticSubscriptions
      )
    end
  end

  defmodule AgentWithMultiSensorPlugin do
    @moduledoc false
    use Jido.Agent,
      middleware: [JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithMultipleSensors]

    agent do
      name "agent_with_multi_sensor_plugin"
    end

    slices do
      slice(
        :multi_sensors,
        JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithMultipleSensors
      )
    end
  end

  defmodule AgentWithNoSubscriptionsPlugin do
    @moduledoc false
    use Jido.Agent,
      middleware: [JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithNoSubscriptions]

    agent do
      name "agent_with_no_subs_plugin"
    end

    slices do
      slice(:no_subs, JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithNoSubscriptions)
    end
  end

  defmodule AgentWithPluginWithoutCallback do
    @moduledoc false
    use Jido.Agent,
      middleware: [
        JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithoutSubscriptionsCallback
      ]

    agent do
      name "agent_with_plugin_without_callback"
    end

    slices do
      slice(
        :no_callback,
        JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithoutSubscriptionsCallback
      )
    end
  end

  defmodule AgentWithMultiplePlugins do
    @moduledoc false
    use Jido.Agent,
      middleware: [
        JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithSensor,
        JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithMultipleSensors
      ]

    agent do
      name "agent_with_multiple_plugins"
    end

    slices do
      slice(:with_sensor, JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithSensor)

      slice(
        :multi_sensors,
        JidoTest.AgentServer.PluginSubscriptionsTest.PluginWithMultipleSensors
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "plugin subscription sensors during post_init" do
    test "starts subscription sensor during post_init", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: AgentWithSensorPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} ->
          match?({:sensor, _, _}, tag)
        end)

      assert length(sensor_children) == 1

      [{tag, child_info}] = sensor_children
      assert {:sensor, PluginWithSensor, TestSensor} = tag
      assert Process.alive?(child_info.pid)

      GenServer.stop(pid)
    end

    test "sensor is monitored by AgentServer", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: AgentWithSensorPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

      [{_tag, child_info}] = sensor_children
      assert child_info.ref != nil

      GenServer.stop(child_info.pid)

      await_state_value(pid, fn s ->
        sensor_count =
          s.children
          |> Enum.count(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

        if sensor_count == 0, do: true
      end)

      GenServer.stop(pid)
    end
  end

  describe "sensor context" do
    test "sensor receives correct context with agent_ref, agent_id, agent_module, plugin_spec", %{
      jido: jido
    } do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: AgentWithSensorPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

      [{_tag, child_info}] = sensor_children

      sensor_state = :sys.get_state(child_info.pid)

      assert is_map(sensor_state.context)
      assert is_binary(sensor_state.context.agent_id)
      assert sensor_state.context.agent_module == AgentWithSensorPlugin
      assert is_tuple(sensor_state.context.agent_ref)
      assert sensor_state.context.plugin_spec != nil
      assert sensor_state.context.plugin_spec.module == PluginWithSensor
      assert sensor_state.context.jido_instance == jido

      GenServer.stop(pid)
    end
  end

  describe "signal delivery to agent" do
    test "sensor signals are delivered to the agent", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: AgentWithRoutedSensorPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

      [{_tag, child_info}] = sensor_children

      Runtime.event(child_info.pid, {:trigger, :test_value})

      %{value: value, count: count} =
        await_state_value(pid, fn s ->
          v = s.agent.state.domain.last_sensor_value
          c = s.agent.state.domain.last_sensor_count

          if v == :test_value and c == 1, do: %{value: v, count: c}
        end)

      assert value == :test_value
      assert count == 1

      GenServer.stop(pid)
    end
  end

  describe "multiple sensors from same plugin" do
    test "starts all sensors from plugin with multiple subscriptions", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: AgentWithMultiSensorPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

      assert length(sensor_children) == 2

      sensor_modules =
        sensor_children
        |> Enum.map(fn {{:sensor, _plugin, sensor_mod}, _} -> sensor_mod end)
        |> Enum.sort()

      assert sensor_modules == [SecondTestSensor, TestSensor]

      Enum.each(sensor_children, fn {_tag, child_info} ->
        assert Process.alive?(child_info.pid)
      end)

      GenServer.stop(pid)
    end
  end

  describe "multiple plugins with sensors" do
    test "starts sensors from all plugins", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: AgentWithMultiplePlugins, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

      assert length(sensor_children) == 3

      plugin_sensor_pairs =
        sensor_children
        |> Enum.map(fn {{:sensor, plugin, sensor}, _} -> {plugin, sensor} end)
        |> Enum.sort()

      assert {PluginWithMultipleSensors, SecondTestSensor} in plugin_sensor_pairs
      assert {PluginWithMultipleSensors, TestSensor} in plugin_sensor_pairs
      assert {PluginWithSensor, TestSensor} in plugin_sensor_pairs

      GenServer.stop(pid)
    end
  end

  describe "plugin with empty subscriptions" do
    test "plugin returning empty list works fine", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: AgentWithNoSubscriptionsPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

      assert sensor_children == []

      GenServer.stop(pid)
    end

    test "plugin without subscriptions callback works fine", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: AgentWithPluginWithoutCallback, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

      assert sensor_children == []

      GenServer.stop(pid)
    end
  end

  describe "sensor child tracking" do
    test "sensors are tracked in agent's children map", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: AgentWithSensorPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      tag = {:sensor, PluginWithSensor, TestSensor}
      assert Map.has_key?(children, tag)

      child_info = Map.get(children, tag)
      assert child_info.module == TestSensor
      assert child_info.meta.plugin == PluginWithSensor
      assert child_info.meta.sensor == TestSensor

      GenServer.stop(pid)
    end
  end

  describe "sensor cleanup on AgentServer stop" do
    test "sensors are cleaned up when AgentServer stops", %{jido: jido} do
      {:ok, pid} = Jido.AgentServer.start_link(agent_module: AgentWithSensorPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} -> match?({:sensor, _, _}, tag) end)

      sensor_pids = Enum.map(sensor_children, fn {_, info} -> info.pid end)

      assert Enum.all?(sensor_pids, &Process.alive?/1)

      GenServer.stop(pid)

      eventually(fn ->
        not Process.alive?(pid)
      end)
    end
  end

  describe "static plugin subscriptions" do
    test "starts static subscription sensor during post_init", %{jido: jido} do
      {:ok, pid} =
        Jido.AgentServer.start_link(agent_module: AgentWithStaticSubscriptionPlugin, jido: jido)

      {:ok, children} = Jido.AgentServer.state(pid, fn s -> {:ok, s.children} end)

      sensor_children =
        children
        |> Enum.filter(fn {tag, _} ->
          match?({:sensor, PluginWithStaticSubscriptions, TestSensor}, tag)
        end)

      assert length(sensor_children) == 1

      # Verify the plugin's static subscriptions surface via Plugin.Info
      assert Jido.Dsl.Plugin.Info.subscriptions(PluginWithStaticSubscriptions) == [
               {TestSensor, %{emit_on_init: true, signal_type: "static.sensor.ready"}}
             ]

      GenServer.stop(pid)
    end

    test "static subscriptions are available via Plugin.Info" do
      assert Jido.Dsl.Plugin.Info.subscriptions(PluginWithStaticSubscriptions) == [
               {TestSensor, %{emit_on_init: true, signal_type: "static.sensor.ready"}}
             ]
    end
  end
end
