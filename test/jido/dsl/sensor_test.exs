defmodule Jido.Dsl.SensorTest do
  use ExUnit.Case, async: true

  alias Jido.Sensor.Spec

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

    test "name/0 returns the configured name" do
      assert FullSensor.name() == "full_sensor"
      assert MinimalSensor.name() == "minimal_sensor"
    end

    test "description/0, category/0, tags/0, vsn/0 round-trip" do
      assert FullSensor.description() == "Full sensor with every accessor populated."
      assert FullSensor.category() == "test"
      assert FullSensor.tags() == ["a", "b"]
      assert FullSensor.vsn() == "1.0.0"
    end

    test "tags/0 defaults to []" do
      assert MinimalSensor.tags() == []
    end

    test "description/0 returns nil when omitted" do
      assert MinimalSensor.description() == nil
    end

    test "schema/0 round-trips a Zoi schema" do
      schema = FullSensor.schema()
      assert is_struct(schema)
      assert {:ok, %{interval: 5000}} = Zoi.parse(schema, %{interval: 5000})
    end

    test "schema/0 returns nil when omitted" do
      assert MinimalSensor.schema() == nil
    end

    test "spec/0 returns a populated Sensor.Spec struct" do
      spec = FullSensor.spec()
      assert %Spec{} = spec
      assert spec.module == FullSensor
      assert spec.name == "full_sensor"
      assert spec.description == "Full sensor with every accessor populated."
      assert spec.schema == FullSensor.schema()
    end

    test "__sensor_metadata__/0 returns the discovery shape" do
      meta = FullSensor.__sensor_metadata__()
      assert meta.name == "full_sensor"
      assert meta.description == "Full sensor with every accessor populated."
      assert meta.schema == FullSensor.schema()
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
