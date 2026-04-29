defmodule Jido.Agent do
  @moduledoc """
  An Agent is an immutable data structure that holds state and can be updated
  via commands. This module provides a minimal, purely functional API:

  - `new/1` - Create a new agent
  - `set/2` - Update state directly
  - `validate/2` - Validate agent state against schema
  - `cmd/2` - Execute actions: `(agent, action) -> {:ok, agent, [directive]} | {:error, reason}`

  ## Core Pattern

  The fundamental operation is `cmd/2`:

      {:ok, agent, directives} = MyAgent.cmd(agent, MyAction)
      {:ok, agent, directives} = MyAgent.cmd(agent, {MyAction, %{value: 42}})
      {:ok, agent, directives} = MyAgent.cmd(agent, [Action1, Action2])

  Multi-instruction `cmd` is **all-or-nothing**: the first `{:error, _}` halts
  the batch, the input agent is returned unchanged, and no directives execute.

  Key invariants:
  - On success the returned `agent` is **always complete** — no "apply
    directives" step needed.
  - On error the input agent is returned via the caller's error branch;
    successful prior instructions' slice changes vanish.
  - `directives` are **external effects only** — they never modify agent state.
  - `cmd/2` is a **pure function** — given same inputs, always same outputs.

  ## Defining an Agent Module

  ```elixir
  defmodule MyAgent do
    use Jido.Agent,
      extensions: [
        MyApp.MemorySlice,
        MyApp.SlackPlugin,
        Jido.Middleware.Retry
      ]

    agent do
      name "my_agent"
      description "My custom agent"
      path :domain
      schema [counter: [type: :integer, default: 0]]
    end

    signal_routes do
      route "user.created", HandleUserCreated
      route "payment.*", LargePayment, priority: 10, match: &(&1.data.amount > 100)
    end

    schedules do
      schedule "*/5 * * * *", "tick.heartbeat"
    end
  end
  ```

  Each module listed in `extensions: […]` that opts into the contribution
  mechanism (`use Jido.Slice.Extension, host_section: …`) surfaces a typed
  configuration block on the host agent — e.g. `memory do … end`,
  `react do … end`. Each contributed section's schema includes a
  built-in `path:` field so the host can rename the slice's mount path
  inline (`memory do path :short_term end`).
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Jido.Dsl.Agent]],
    untyped_extensions?: false,
    opt_schema: [
      extensions: [
        type: {:list, :any},
        default: [],
        doc: "Plugin / slice / middleware modules registered with this agent."
      ],
      jido: [
        type: :atom,
        doc: "Optional Jido instance module for resolving default slices at compile time."
      ],
      default_slices: [
        type: :any,
        doc:
          "Override default slices: false to disable all, or %{path => false | Module | {Module, config}}."
      ]
    ]

  defmacro __using__(opts) do
    env = __CALLER__

    user_extensions =
      opts
      |> Keyword.get(:extensions, [])
      |> List.wrap()

    shadow_extensions =
      user_extensions
      |> Enum.flat_map(&Jido.Agent.__shadow_extensions__(&1, env))
      |> Enum.uniq()

    new_opts =
      if shadow_extensions == [] do
        opts
      else
        Keyword.update(opts, :extensions, shadow_extensions, fn current ->
          List.wrap(current) ++ shadow_extensions
        end)
      end

    super(new_opts)
  end

  @doc false
  @spec __shadow_extensions__(term(), Macro.Env.t()) :: [module()]
  def __shadow_extensions__(entry, env) do
    case __extract_module__(entry, env) do
      nil ->
        []

      module ->
        with {:module, _} <- Code.ensure_compiled(module),
             true <- function_exported?(module, :__jido_host_extension_module__, 0),
             shadow when is_atom(shadow) <- module.__jido_host_extension_module__(),
             {:module, _} <- Code.ensure_compiled(shadow) do
          [shadow]
        else
          _ -> []
        end
    end
  end

  defp __extract_module__({:__aliases__, _meta, _segments} = ast, env) do
    case Macro.expand(ast, env) do
      module when is_atom(module) -> module
      _ -> nil
    end
  end

  defp __extract_module__({entry, _opts}, env), do: __extract_module__(entry, env)
  defp __extract_module__(module, _env) when is_atom(module), do: module
  defp __extract_module__(_other, _env), do: nil

  @doc false
  @spec __spark_extension_module__?(term()) :: boolean()
  def __spark_extension_module__?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and Spark.implements_behaviour?(module, Spark.Dsl.Extension)
  end

  def __spark_extension_module__?(_), do: false

  alias Jido.Agent
  alias Jido.Agent.Directive
  alias Jido.Agent.State, as: StateHelper
  alias Jido.Error
  alias Jido.Instruction
  alias Jido.Plugin.Instance, as: PluginInstance
  alias Jido.Slice.Instance, as: SliceInstance

  @doc false
  def expand_aliases_in_ast(ast, caller_env) do
    Macro.prewalk(ast, fn
      {:__aliases__, _, _} = alias_node -> Macro.expand(alias_node, caller_env)
      other -> other
    end)
  end

  @doc false
  def expand_and_eval_literal_option(value, caller_env) do
    case value do
      nil ->
        nil

      value when is_atom(value) or is_binary(value) or is_number(value) ->
        value

      %_{} = struct ->
        struct

      {:__aliases__, _, _} = alias_node ->
        Macro.expand(alias_node, caller_env)

      value when is_list(value) ->
        Enum.map(value, fn
          {key, nested_value} ->
            {
              expand_and_eval_literal_option(key, caller_env),
              expand_and_eval_literal_option(nested_value, caller_env)
            }

          nested_value ->
            expand_and_eval_literal_option(nested_value, caller_env)
        end)

      value when is_map(value) ->
        Map.new(value, fn {key, nested_value} ->
          {
            expand_and_eval_literal_option(key, caller_env),
            expand_and_eval_literal_option(nested_value, caller_env)
          }
        end)

      value when is_tuple(value) ->
        if ast_node?(value) do
          value
          |> expand_aliases_in_ast(caller_env)
          |> Code.eval_quoted([], caller_env)
          |> elem(0)
        else
          value
          |> Tuple.to_list()
          |> Enum.map(&expand_and_eval_literal_option(&1, caller_env))
          |> List.to_tuple()
        end

      other ->
        other
    end
  end

  defp ast_node?({_, meta, _}) when is_list(meta), do: true
  defp ast_node?(_other), do: false

  require OK

  @schema Zoi.struct(
            __MODULE__,
            %{
              id:
                Zoi.string(description: "Unique agent identifier")
                |> Zoi.optional(),
              agent_module:
                Zoi.atom(description: "Concrete agent module that created this struct")
                |> Zoi.optional(),
              name:
                Zoi.string(description: "Agent name")
                |> Zoi.optional(),
              description:
                Zoi.string(description: "Agent description")
                |> Zoi.optional(),
              category:
                Zoi.string(description: "Agent category")
                |> Zoi.optional(),
              tags:
                Zoi.list(Zoi.string(), description: "Tags")
                |> Zoi.default([]),
              vsn:
                Zoi.string(description: "Version")
                |> Zoi.optional(),
              schema:
                Zoi.any(
                  description: "NimbleOptions or Zoi schema for validating the Agent's state"
                )
                |> Zoi.default([]),
              state:
                Zoi.map(description: "Current state")
                |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Agent."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  # Action input types
  @type action :: module() | {module(), map()} | Instruction.t() | [action()]

  # Directive types (external effects only - never modify agent state)
  @type directive :: Directive.t()

  @type agent_result :: {:ok, t()} | {:error, Error.t()}
  @type cmd_result :: {:ok, t(), [directive()]} | {:error, term()}

  @doc """
  Returns signal routes for this agent.
  """
  @callback signal_routes() :: [Jido.Signal.Router.route_spec()]
  @callback signal_routes(ctx :: map()) :: [Jido.Signal.Router.route_spec()]

  @doc """
  Optional persistence hooks.
  """
  @callback checkpoint(agent :: t(), ctx :: map()) :: {:ok, map()} | {:error, term()}
  @callback restore(checkpoint :: map(), ctx :: map()) :: {:ok, t()} | {:error, term()}

  @optional_callbacks [
    signal_routes: 0,
    signal_routes: 1,
    checkpoint: 2,
    restore: 2
  ]

  @impl Spark.Dsl
  def handle_opts(opts) do
    user_extensions =
      opts
      |> Keyword.get(:extensions, [])
      |> List.wrap()
      |> Enum.reject(&__spark_extension_module__?/1)

    quote location: :keep do
      @behaviour Jido.Agent

      alias Jido.Agent
      alias Jido.Agent.Directive, as: AgentDirective
      alias Jido.Agent.SliceUpdate
      alias Jido.Agent.State, as: AgentState
      alias Jido.Instruction
      alias Jido.Observe.Config, as: ObserveConfig
      alias Jido.Plugin.Requirements, as: PluginRequirements

      require OK

      @persist {:jido_user_extensions, unquote(Macro.escape(user_extensions))}
      @persist {:jido_instance_module, unquote(opts[:jido])}
      @persist {:default_slices_override, unquote(Macro.escape(opts[:default_slices]))}
    end
  end

  @doc false
  @spec __resolve_default_slices__(map()) :: [module() | {module(), map()}]
  def __resolve_default_slices__(agent_opts) do
    jido_module = agent_opts[:jido]

    base_defaults =
      if jido_module != nil and function_exported?(jido_module, :__default_slices__, 0) do
        jido_module.__default_slices__()
      else
        Jido.Agent.DefaultSlices.package_defaults()
      end

    Jido.Agent.DefaultSlices.apply_agent_overrides(base_defaults, agent_opts[:default_slices])
  end

  @doc false
  @spec __seed_own_slice__(term(), map()) :: map()
  def __seed_own_slice__([], user_value), do: user_value

  def __seed_own_slice__(nil, user_value), do: user_value

  def __seed_own_slice__(schema, user_value) when is_list(schema) do
    defaults = Jido.Agent.State.defaults_from_schema(schema)
    Map.merge(defaults, user_value)
  end

  def __seed_own_slice__(schema, user_value) do
    case Zoi.parse(schema, user_value) do
      {:ok, validated} ->
        validated

      {:error, errors} ->
        raise Jido.Agent.SliceValidationError,
          path: nil,
          module: nil,
          errors: errors
    end
  end

  @doc false
  @spec __seed_plugin_slice__(module(), map()) :: term()
  def __seed_plugin_slice__(plugin_module, %{} = merged_input) do
    case Jido.Dsl.Slice.Info.schema(plugin_module) do
      nil ->
        if map_size(merged_input) == 0, do: nil, else: merged_input

      schema ->
        seed_plugin_slice_from_schema(plugin_module, schema, merged_input)
    end
  end

  defp seed_plugin_slice_from_schema(plugin_module, schema, merged_input) do
    case Zoi.parse(schema, merged_input) do
      {:ok, validated} ->
        validated

      {:error, _errors} when map_size(merged_input) == 0 ->
        # Schema has required fields without defaults and the user supplied
        # nothing — preserve the lazy-init contract: the slice starts as nil
        # and an action (typically `Ensure`) materializes it on demand.
        nil

      {:error, errors} ->
        raise Jido.Agent.SliceValidationError,
          path: Jido.Dsl.Slice.Info.path(plugin_module),
          module: plugin_module,
          errors: errors
    end
  end

  @doc false
  @spec __normalize_plugin_instances__([module() | {module(), map()}]) :: [PluginInstance.t()]
  def __normalize_plugin_instances__(plugins) do
    Enum.map(plugins, &PluginInstance.new/1)
  end

  @doc false
  @spec __normalize_slice_instances__([module() | {module(), map() | keyword()}]) ::
          [SliceInstance.t()]
  def __normalize_slice_instances__(slices) do
    Enum.map(slices, &SliceInstance.new/1)
  end

  # ---------------------------------------------------------------------------
  # Base module functions (for direct use without `use`)
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new agent from attributes.

  For module-based agents, use `MyAgent.new/1` instead.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    attrs_with_id = normalize_agent_id(attrs)

    case Zoi.parse(@schema, attrs_with_id) do
      {:ok, agent} ->
        {:ok, agent}

      {:error, errors} ->
        {:error, Error.validation_error("Agent validation failed", %{errors: errors})}
    end
  end

  @doc """
  Updates agent state by merging new attributes.
  """
  @spec set(t(), map() | keyword()) :: agent_result()
  def set(%Agent{} = agent, attrs) do
    new_state = StateHelper.merge(agent.state, Map.new(attrs))
    OK.success(%{agent | state: new_state})
  end

  @doc """
  Validates agent state against its schema.
  """
  @spec validate(t(), keyword()) :: agent_result()
  def validate(%Agent{} = agent, opts \\ []) do
    case StateHelper.validate(agent.state, agent.schema, opts) do
      {:ok, validated_state} ->
        OK.success(%{agent | state: validated_state})

      {:error, reason} ->
        Error.validation_error("State validation failed", %{reason: reason})
        |> OK.failure()
    end
  end

  defp normalize_agent_id(attrs) do
    case Map.get(attrs, :id) do
      nil -> Map.put(attrs, :id, Jido.Util.generate_id())
      "" -> Map.put(attrs, :id, Jido.Util.generate_id())
      _ -> attrs
    end
  end
end
