defmodule Jido.Dsl.SensorTest do
  use ExUnit.Case, async: true

  alias Jido.Dsl.Sensor.Info, as: SensorInfo

  describe "sectioned DSL accessor parity" do
    defmodule MinimalSensor do
      @moduledoc false
      use Jido.Sensor

      sensor do
        name "minimal_sensor"
      end

      @impl Jido.Sensor
      def init(_config, _ctx), do: {:ok, %{}}

      @impl Jido.Sensor
      def handle_event(_event, state), do: {:ok, state}
    end

    defmodule FullSensor do
      @moduledoc false
      use Jido.Sensor

      sensor do
        name "full_sensor"
        description "Full sensor with every accessor populated."
        category "test"
        tags ["a", "b"]
        vsn "1.0.0"
        schema(Zoi.object(%{interval: Zoi.integer() |> Zoi.default(1000)}))
      end

      @impl Jido.Sensor
      def init(_config, _ctx), do: {:ok, %{}}

      @impl Jido.Sensor
      def handle_event(_event, state), do: {:ok, state}
    end

    test "name/1 returns the configured name" do
      assert SensorInfo.name(FullSensor) == "full_sensor"
      assert SensorInfo.name(MinimalSensor) == "minimal_sensor"
    end

    test "description/1, category/1, tags/1, vsn/1 round-trip" do
      assert SensorInfo.description(FullSensor) == "Full sensor with every accessor populated."
      assert SensorInfo.category(FullSensor) == "test"
      assert SensorInfo.tags(FullSensor) == ["a", "b"]
      assert SensorInfo.vsn(FullSensor) == "1.0.0"
    end

    test "tags/1 defaults to []" do
      assert SensorInfo.tags(MinimalSensor) == []
    end

    test "description/1 returns nil when omitted" do
      assert SensorInfo.description(MinimalSensor) == nil
    end

    test "schema/1 round-trips a Zoi schema" do
      schema = SensorInfo.schema(FullSensor)
      assert is_struct(schema)
      assert {:ok, %{interval: 5000}} = Zoi.parse(schema, %{interval: 5000})
    end

    test "schema/1 returns nil when omitted" do
      assert SensorInfo.schema(MinimalSensor) == nil
    end

    test "Spark.Dsl.is?(mod, Jido.Sensor) is true for sensor modules" do
      assert Spark.Dsl.is?(FullSensor, Jido.Sensor)
      assert Spark.Dsl.is?(MinimalSensor, Jido.Sensor)
    end
  end

  describe "default terminate/2" do
    defmodule TerminateSensor do
      @moduledoc false
      use Jido.Sensor

      sensor do
        name "terminate_sensor"
      end

      @impl Jido.Sensor
      def init(_config, _ctx), do: {:ok, %{}}

      @impl Jido.Sensor
      def handle_event(_event, state), do: {:ok, state}
    end

    test "default terminate/2 returns :ok" do
      assert TerminateSensor.terminate(:normal, %{}) == :ok
    end
  end

  describe "behaviour" do
    test "modules use Jido.Sensor implement the @behaviour" do
      defmodule BehaviourCheckSensor do
        @moduledoc false
        use Jido.Sensor

        sensor do
          name "behaviour_check_sensor"
        end

        @impl Jido.Sensor
        def init(_config, _ctx), do: {:ok, %{}}

        @impl Jido.Sensor
        def handle_event(_event, state), do: {:ok, state}
      end

      behaviours =
        BehaviourCheckSensor.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Sensor in behaviours
    end
  end
end
