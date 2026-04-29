defmodule Jido.Dsl.Action.Transformers.GenerateAccessors do
  @moduledoc """
  Final transformer in the action DSL pipeline. Emits the runtime-only
  pieces of the action's compile-time surface that are not introspection:

    * `validate_params/1` and `validate_output/1` — runtime delegates
      that close over `__MODULE__`.
    * The default lifecycle hook impls (`on_before_validate_params/1`,
      `on_after_validate_params/1`, `on_before_validate_output/1`,
      `on_after_validate_output/1`, `on_after_run/1`) plus the
      associated `defoverridable` block.

  Action introspection itself lives in `Jido.Dsl.Action.Info`.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(_), do: true

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    block =
      quote location: :keep do
        unquote(quoted_validation())
        unquote(quoted_hooks())
      end

    {:ok, Transformer.eval(dsl_state, [], block)}
  end

  defp quoted_validation do
    quote do
      @doc "Validates the input parameters for the Action."
      @spec validate_params(map()) :: {:ok, map()} | {:error, any()}
      def validate_params(params), do: Jido.Action.Runtime.validate_params(params, __MODULE__)

      @doc "Validates the output result for the Action."
      @spec validate_output(map()) :: {:ok, map()} | {:error, any()}
      def validate_output(output), do: Jido.Action.Runtime.validate_output(output, __MODULE__)
    end
  end

  defp quoted_hooks do
    quote do
      @impl Jido.Action
      @doc "Lifecycle hook called before parameter validation."
      def on_before_validate_params(params), do: {:ok, params}

      @impl Jido.Action
      @doc "Lifecycle hook called after parameter validation."
      def on_after_validate_params(params), do: {:ok, params}

      @impl Jido.Action
      @doc "Lifecycle hook called before output validation."
      def on_before_validate_output(output), do: {:ok, output}

      @impl Jido.Action
      @doc "Lifecycle hook called after output validation."
      def on_after_validate_output(output), do: {:ok, output}

      @impl Jido.Action
      @doc "Lifecycle hook called after Action execution."
      def on_after_run(result), do: result

      defoverridable on_before_validate_params: 1,
                     on_after_validate_params: 1,
                     on_before_validate_output: 1,
                     on_after_validate_output: 1,
                     on_after_run: 1
    end
  end
end
