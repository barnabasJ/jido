defmodule Jido.Dsl.Action.Transformers.GenerateAccessors do
  @moduledoc """
  Final transformer in the action DSL pipeline.

  Reads the `action do … end` section defined by `Jido.Dsl.Action` and
  emits, into the user's action module, the same compile-time accessor
  surface today's `Jido.Action.__using__/1` macro emits — `name/0`,
  `description/0`, `category/0`, `tags/0`, `vsn/0`, `path/0`,
  `schema/0`, `output_schema/0`, `to_json/0`, `to_tool/0`,
  `__action_metadata__/0`, `validate_params/1`, `validate_output/1`,
  plus the lifecycle hook surface and its `defoverridable` block.
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
        unquote(quoted_serialization())
        unquote(quoted_validation())
        unquote(quoted_hooks())
      end

    {:ok, Transformer.eval(dsl_state, [], block)}
  end

  defp collect_state(dsl_state) do
    %{
      name: Spark.Dsl.Extension.get_opt(dsl_state, [:action], :name),
      description: Spark.Dsl.Extension.get_opt(dsl_state, [:action], :description),
      category: Spark.Dsl.Extension.get_opt(dsl_state, [:action], :category),
      tags: Spark.Dsl.Extension.get_opt(dsl_state, [:action], :tags) || [],
      vsn: Spark.Dsl.Extension.get_opt(dsl_state, [:action], :vsn),
      path: Spark.Dsl.Extension.get_opt(dsl_state, [:action], :path),
      compensation:
        Spark.Dsl.Extension.get_opt(
          dsl_state,
          [:action],
          :compensation,
          %{enabled: false, max_retries: 1, timeout: 5000}
        ),
      schema: Spark.Dsl.Extension.get_opt(dsl_state, [:action], :schema, []),
      output_schema: Spark.Dsl.Extension.get_opt(dsl_state, [:action], :output_schema, [])
    }
  end

  defp quoted_module_attributes(state) do
    quote do
      @jido_action_name unquote(state.name)
      @jido_action_description unquote(state.description)
      @jido_action_category unquote(state.category)
      @jido_action_tags unquote(Macro.escape(state.tags))
      @jido_action_vsn unquote(state.vsn)
      @jido_action_path unquote(Macro.escape(state.path))
      @jido_action_compensation unquote(Macro.escape(state.compensation))
      @jido_action_schema unquote(Macro.escape(state.schema))
      @jido_action_output_schema unquote(Macro.escape(state.output_schema))
    end
  end

  defp quoted_basic_accessors do
    quote do
      @doc "Returns the name of the Action."
      @spec name() :: String.t()
      def name, do: @jido_action_name

      @doc "Returns the description of the Action."
      @spec description() :: String.t() | nil
      def description, do: @jido_action_description

      @doc "Returns the category of the Action."
      @spec category() :: String.t() | nil
      def category, do: @jido_action_category

      @doc "Returns the tags associated with the Action."
      @spec tags() :: [String.t()]
      def tags, do: @jido_action_tags

      @doc "Returns the version of the Action."
      @spec vsn() :: String.t() | nil
      def vsn, do: @jido_action_vsn

      @doc "Returns the slice path this Action operates on (atom, list, or nil)."
      @spec path() :: atom() | [atom()] | nil
      def path, do: @jido_action_path

      @doc "Returns the input schema of the Action."
      @spec schema() :: term()
      def schema, do: @jido_action_schema

      @doc "Returns the output schema of the Action."
      @spec output_schema() :: term()
      def output_schema, do: @jido_action_output_schema
    end
  end

  defp quoted_serialization do
    quote do
      @doc "Returns the Action metadata as a JSON-serializable map."
      @spec to_json() :: map()
      def to_json do
        %{
          name: @jido_action_name,
          description: @jido_action_description,
          category: @jido_action_category,
          tags: @jido_action_tags,
          vsn: @jido_action_vsn,
          path: @jido_action_path,
          compensation: @jido_action_compensation,
          schema: schema(),
          output_schema: output_schema()
        }
      end

      @doc "Converts the Action to an LLM-compatible tool format."
      def to_tool do
        Jido.Action.Tool.to_tool(__MODULE__, strict: true)
      end

      @doc "Returns the Action metadata. Alias for `to_json/0`."
      @spec __action_metadata__() :: map()
      def __action_metadata__, do: to_json()
    end
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

      defoverridable name: 0,
                     description: 0,
                     category: 0,
                     tags: 0,
                     vsn: 0,
                     path: 0,
                     schema: 0,
                     output_schema: 0,
                     on_before_validate_params: 1,
                     on_after_validate_params: 1,
                     on_before_validate_output: 1,
                     on_after_validate_output: 1,
                     on_after_run: 1
    end
  end
end
