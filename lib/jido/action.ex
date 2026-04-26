defmodule Jido.Action do
  @moduledoc """
  An Action reduces a slice of agent state in response to a signal.

  ## Callback shape

      run(signal, slice, opts, ctx) ::
        {:ok, new_slice, [directive]}
        | {:error, reason}

  Always a 3-tuple on success — even when no directives are emitted, the
  list is empty. There is no `{:ok, slice}` two-arg variant and no
  `{:error, reason, [directive]}` variant; if it failed, it failed —
  emit observability via middleware on the failure path. See
  [ADR 0018](../adr/0018-tagged-tuple-return-shape.md).

  - `signal`: the `Jido.Signal.t()` that triggered the action. Action type
    is `signal.type`; payload is `signal.data`. Per-signal runtime ctx is
    at `signal.extensions[:jido_ctx]` (already extracted and passed as the
    `ctx` arg).
  - `slice`: the current value of `agent.state[path]`, where `path` is the
    action's declared `path:` option. Actions own their slice's next value —
    return the full new slice, not a patch.
  - `opts`: static options attached at route registration. From
    `{"work.start", {MyAction, %{max_retries: 3}}}`, `opts = %{max_retries: 3}`.
    Defaults to `%{}`.
  - `ctx`: per-signal runtime context (user, trace, tenant, parent,
    partition, agent_id). Propagates to emitted signals' `extensions[:jido_ctx]`
    by default; middleware can augment or strip before forwarding.

  Bare-atom or string `reason` values returned in `{:error, reason}` are
  wrapped into `%Jido.Error{}` at the cmd boundary via
  `Jido.Error.from_term/1`, so consumers always see a structured error.

  ## Defining an Action

      defmodule Counter.Increment do
        use Jido.Action,
          name: "increment",
          path: :counter,
          schema: [by: [type: :integer, default: 1]]

        @impl true
        def run(%Jido.Signal{data: %{by: by}}, slice, _opts, _ctx) do
          {:ok, %{slice | count: (slice[:count] || 0) + by}, []}
        end
      end

  ## Parameter and Output Validation

  > **Note on Validation:** Validation is intentionally open — only fields
  > specified in `schema` and `output_schema` are validated. Unspecified
  > fields are not validated, allowing easier action composition and
  > pass-through of additional parameters.
  """

  alias Jido.Action.Error
  alias Jido.Action.Tool

  @schema Zoi.struct(
            __MODULE__,
            %{
              name:
                Zoi.string(description: "The name of the Action")
                |> Zoi.refine({Jido.Action.Util, :validate_name, []}),
              description: Zoi.string(description: "Description") |> Zoi.optional(),
              category: Zoi.string(description: "Category") |> Zoi.optional(),
              tags: Zoi.list(Zoi.string(), description: "Tags") |> Zoi.default([]),
              vsn: Zoi.string(description: "Version") |> Zoi.optional(),
              schema:
                Zoi.any(description: "NimbleOptions or Zoi schema for validating Action input")
                |> Zoi.default([]),
              output_schema:
                Zoi.any(description: "NimbleOptions or Zoi schema for validating Action output")
                |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @action_config_schema Zoi.object(%{
                          name:
                            Zoi.string(
                              description:
                                "The name of the Action. Must contain only letters, numbers, and underscores."
                            )
                            |> Zoi.refine({Jido.Action.Util, :validate_name, []}),
                          description:
                            Zoi.string(description: "A description of what the Action does.")
                            |> Zoi.optional(),
                          category:
                            Zoi.string(description: "The category of the Action.")
                            |> Zoi.optional(),
                          tags:
                            Zoi.list(Zoi.string(),
                              description: "A list of tags associated with the Action."
                            )
                            |> Zoi.default([]),
                          vsn:
                            Zoi.string(description: "The version of the Action.")
                            |> Zoi.optional(),
                          path:
                            Zoi.any(
                              description:
                                "The slice key (atom) or path (list of atoms) this action operates on. Optional during migration; will be required."
                            )
                            |> Zoi.optional(),
                          compensation:
                            Zoi.object(%{
                              enabled: Zoi.boolean() |> Zoi.default(false),
                              max_retries: Zoi.integer() |> Zoi.min(0) |> Zoi.default(1),
                              timeout: Zoi.integer() |> Zoi.min(0) |> Zoi.default(5000)
                            })
                            |> Zoi.default(%{enabled: false, max_retries: 1, timeout: 5000}),
                          schema:
                            Zoi.any(
                              description:
                                "A NimbleOptions or Zoi schema for validating the Action's input parameters."
                            )
                            |> Zoi.refine({Jido.Action.Schema, :validate_config_schema, []})
                            |> Zoi.default([]),
                          output_schema:
                            Zoi.any(
                              description:
                                "A NimbleOptions or Zoi schema for validating the Action's output. Only specified fields are validated."
                            )
                            |> Zoi.refine({Jido.Action.Schema, :validate_config_schema, []})
                            |> Zoi.default([])
                        })

  @validate_params_doc """
  Validates the input parameters for the Action.
  """

  @validate_output_doc """
  Validates the output result for the Action.
  """

  @doc """
  Defines a new Action module.
  """
  defmacro __using__(opts_ast) do
    escaped_schema = Macro.escape(@action_config_schema)
    validate_params_doc = @validate_params_doc
    validate_output_doc = @validate_output_doc

    {schema_ast, output_schema_ast} =
      if is_list(opts_ast) do
        {Keyword.get(opts_ast, :schema), Keyword.get(opts_ast, :output_schema)}
      else
        {nil, nil}
      end

    metadata_ast = action_metadata_ast(schema_ast, output_schema_ast)
    serialization_ast = action_serialization_ast()
    validation_ast = action_validation_ast(validate_params_doc, validate_output_doc)
    hooks_ast = action_hooks_ast()

    quote location: :keep do
      @behaviour Jido.Action
      @before_compile Jido.Action

      alias Jido.Action
      alias Jido.Action.Runtime
      alias Jido.Action.Util
      alias Jido.Instruction
      alias Jido.Signal

      opts_map =
        if is_list(unquote(opts_ast)) and Keyword.keyword?(unquote(opts_ast)) do
          unquote(opts_ast)
          |> Map.new(&Util.convert_nested_opt/1)
        else
          unquote(opts_ast)
        end

      case Zoi.parse(unquote(escaped_schema), opts_map) do
        {:ok, validated_opts} ->
          validated_opts =
            if is_struct(validated_opts),
              do: Map.from_struct(validated_opts),
              else: validated_opts

          if unquote(is_nil(schema_ast)) do
            @__jido_schema__ Map.get(validated_opts, :schema, [])
          end

          if unquote(is_nil(output_schema_ast)) do
            @__jido_output_schema__ Map.get(validated_opts, :output_schema, [])
          end

          @validated_opts Map.drop(validated_opts, [:schema, :output_schema])

          unquote(metadata_ast)
          unquote(serialization_ast)
          unquote(validation_ast)
          unquote(hooks_ast)

        {:error, errors} ->
          message =
            if is_list(errors) do
              "Action configuration validation failed:\n" <> Zoi.prettify_errors(errors)
            else
              "Action configuration validation failed: #{inspect(errors)}"
            end

          raise CompileError, description: message, file: __ENV__.file, line: __ENV__.line
      end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    if Module.defines?(env.module, {:run, 4}) do
      nil
    else
      # No `run/4` defined — install a default that errors at runtime.
      quote do
        @impl true
        def run(_signal, _slice, _opts, _ctx) do
          "run/4 must be implemented in your Action"
          |> Jido.Action.Error.config_error()
          |> then(&{:error, &1})
        end
      end
    end
  end

  defp action_metadata_ast(schema_ast, output_schema_ast) do
    quote location: :keep do
      unquote(basic_metadata_functions_ast())
      unquote(schema_function_ast(schema_ast))
      unquote(output_schema_function_ast(output_schema_ast))
    end
  end

  defp basic_metadata_functions_ast do
    quote location: :keep do
      @doc "Returns the name of the Action."
      def name, do: @validated_opts[:name]

      @doc "Returns the description of the Action."
      def description, do: @validated_opts[:description]

      @doc "Returns the category of the Action."
      def category, do: @validated_opts[:category]

      @doc "Returns the tags associated with the Action."
      def tags, do: @validated_opts[:tags]

      @doc "Returns the version of the Action."
      def vsn, do: @validated_opts[:vsn]

      @doc "Returns the slice path this Action operates on (atom, list, or nil)."
      def path, do: @validated_opts[:path]
    end
  end

  defp schema_function_ast(schema_ast) do
    quote location: :keep do
      @doc "Returns the input schema of the Action."
      if unquote(schema_ast) do
        def schema, do: unquote(schema_ast)
      else
        def schema, do: @__jido_schema__
      end
    end
  end

  defp output_schema_function_ast(output_schema_ast) do
    quote location: :keep do
      @doc "Returns the output schema of the Action."
      if unquote(output_schema_ast) do
        def output_schema, do: unquote(output_schema_ast)
      else
        def output_schema, do: @__jido_output_schema__
      end
    end
  end

  defp action_serialization_ast do
    quote location: :keep do
      @doc "Returns the Action metadata as a JSON-serializable map."
      def to_json do
        %{
          name: @validated_opts[:name],
          description: @validated_opts[:description],
          category: @validated_opts[:category],
          tags: @validated_opts[:tags],
          vsn: @validated_opts[:vsn],
          path: @validated_opts[:path],
          compensation: @validated_opts[:compensation],
          schema: schema(),
          output_schema: output_schema()
        }
      end

      @doc "Converts the Action to an LLM-compatible tool format."
      def to_tool do
        Tool.to_tool(__MODULE__, strict: true)
      end

      @doc "Returns the Action metadata. Alias for to_json/0."
      def __action_metadata__ do
        to_json()
      end
    end
  end

  defp action_validation_ast(validate_params_doc, validate_output_doc) do
    quote location: :keep do
      @doc unquote(validate_params_doc)
      @spec validate_params(map()) :: {:ok, map()} | {:error, String.t()}
      def validate_params(params), do: Runtime.validate_params(params, __MODULE__)

      @doc unquote(validate_output_doc)
      @spec validate_output(map()) :: {:ok, map()} | {:error, String.t()}
      def validate_output(output), do: Runtime.validate_output(output, __MODULE__)
    end
  end

  defp action_hooks_ast do
    quote location: :keep do
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

  @doc """
  Executes the Action.

  Implementing modules must define `run/4`, returning
  `{:ok, new_slice, [directive]} | {:error, reason}`. See module doc.
  """
  @callback run(
              signal :: Jido.Signal.t() | map(),
              slice :: term(),
              opts :: map(),
              ctx :: map()
            ) ::
              {:ok, new_slice :: term(), [Jido.Agent.Directive.t()]}
              | {:error, term()}

  @callback on_before_validate_params(params :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_validate_params(params :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_before_validate_output(output :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_validate_output(output :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_run(result :: {:ok, term(), [Jido.Agent.Directive.t()]} | {:error, any()}) ::
              {:ok, term(), [Jido.Agent.Directive.t()]} | {:error, any()}

  @optional_callbacks [
    on_before_validate_params: 1,
    on_after_validate_params: 1,
    on_before_validate_output: 1,
    on_after_validate_output: 1,
    on_after_run: 1
  ]

  @doc """
  Raises an error indicating that Actions cannot be defined at runtime.
  """
  @spec new() :: {:error, Exception.t()}
  @spec new(map() | keyword()) :: {:error, Exception.t()}
  def new, do: new(%{})

  def new(_map_or_kwlist) do
    "Actions should not be defined at runtime"
    |> Error.config_error()
    |> then(&{:error, &1})
  end
end
