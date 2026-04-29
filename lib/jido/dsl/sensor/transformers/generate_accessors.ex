defmodule Jido.Dsl.Sensor.Transformers.GenerateAccessors do
  @moduledoc """
  Final transformer in the sensor DSL pipeline.

  Reads the `sensor do … end` section defined by `Jido.Dsl.Sensor` and
  emits, into the user's sensor module, the same compile-time accessor
  surface today's `Jido.Sensor.__using__/1` macro emits — `name/0`,
  `description/0`, `category/0`, `tags/0`, `vsn/0`, `schema/0`,
  `spec/0`, `__sensor_metadata__/0`, plus the default `terminate/2` and
  its `defoverridable` block.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(_), do: true

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    state = collect_state(dsl_state)

    block =
      quote location: :keep do
        unquote(quoted_module_attributes(state))
        unquote(quoted_basic_accessors())
        unquote(quoted_spec_and_metadata())
        unquote(quoted_terminate())
      end

    {:ok, Transformer.eval(dsl_state, [], block)}
  end

  defp collect_state(dsl_state) do
    %{
      name: Spark.Dsl.Extension.get_opt(dsl_state, [:sensor], :name),
      description: Spark.Dsl.Extension.get_opt(dsl_state, [:sensor], :description),
      category: Spark.Dsl.Extension.get_opt(dsl_state, [:sensor], :category),
      tags: Spark.Dsl.Extension.get_opt(dsl_state, [:sensor], :tags) || [],
      vsn: Spark.Dsl.Extension.get_opt(dsl_state, [:sensor], :vsn),
      schema: Spark.Dsl.Extension.get_opt(dsl_state, [:sensor], :schema)
    }
  end

  defp quoted_module_attributes(state) do
    quote do
      @jido_sensor_name unquote(state.name)
      @jido_sensor_description unquote(state.description)
      @jido_sensor_category unquote(state.category)
      @jido_sensor_tags unquote(Macro.escape(state.tags))
      @jido_sensor_vsn unquote(state.vsn)
      @jido_sensor_schema unquote(Macro.escape(state.schema))
    end
  end

  defp quoted_basic_accessors do
    quote do
      @doc "Returns the sensor's name."
      @spec name() :: String.t()
      def name, do: @jido_sensor_name

      @doc "Returns the sensor's description."
      @spec description() :: String.t() | nil
      def description, do: @jido_sensor_description

      @doc "Returns the sensor's category."
      @spec category() :: String.t() | nil
      def category, do: @jido_sensor_category

      @doc "Returns the sensor's tags."
      @spec tags() :: [String.t()]
      def tags, do: @jido_sensor_tags

      @doc "Returns the sensor's version."
      @spec vsn() :: String.t() | nil
      def vsn, do: @jido_sensor_vsn

      @doc "Returns the Zoi schema for sensor configuration."
      @spec schema() :: term() | nil
      def schema, do: @jido_sensor_schema
    end
  end

  defp quoted_spec_and_metadata do
    quote do
      @doc """
      Returns the sensor specification.

      The spec contains all metadata needed to configure and run the sensor.
      """
      @spec spec() :: Jido.Sensor.Spec.t()
      def spec do
        Jido.Sensor.Spec.new!(%{
          module: __MODULE__,
          name: name(),
          description: description(),
          schema: schema()
        })
      end

      @doc """
      Returns metadata for `Jido.Discovery` integration.
      """
      @spec __sensor_metadata__() :: map()
      def __sensor_metadata__ do
        %{
          name: name(),
          description: description(),
          schema: schema()
        }
      end
    end
  end

  defp quoted_terminate do
    quote do
      @doc false
      @impl Jido.Sensor
      @spec terminate(term(), term()) :: :ok
      def terminate(_reason, _state), do: :ok

      defoverridable name: 0,
                     description: 0,
                     category: 0,
                     tags: 0,
                     vsn: 0,
                     schema: 0,
                     terminate: 2
    end
  end
end
