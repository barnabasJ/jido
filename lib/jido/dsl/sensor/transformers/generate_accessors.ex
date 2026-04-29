defmodule Jido.Dsl.Sensor.Transformers.GenerateAccessors do
  @moduledoc """
  Final transformer in the sensor DSL pipeline. Emits the default
  `terminate/2` impl with a `defoverridable` so an author may override
  it. Sensor introspection itself lives in `Jido.Dsl.Sensor.Info`.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(_), do: true

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    block =
      quote location: :keep do
        @doc false
        @impl Jido.Sensor
        @spec terminate(term(), term()) :: :ok
        def terminate(_reason, _state), do: :ok

        defoverridable terminate: 2
      end

    {:ok, Transformer.eval(dsl_state, [], block)}
  end
end
