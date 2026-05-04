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
      middleware: [Jido.Middlewares.Retry]

    agent do
      name "my_agent"
      description "My custom agent"
      path :domain
      schema [counter: [type: :integer, default: 0]]
    end

    slices do
      slice :memory, MyApp.MemorySlice
      slice :slack, MyApp.SlackPlugin do
        options token: "xoxb-..."
      end
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

  Each `slice :path, Module` line in `slices do … end` mounts a slice
  (or plugin) at the agent-declared path. Plugin modules with
  middleware behaviour also appear in the top-level `middleware: […]`
  list so their position in the wrap chain is explicit.

  The `extensions: […]` keyword stays available for modules whose typed
  DSL section the host wants to call into (e.g. `extensions: [Jido.Slices.AiReact]`
  unlocks `react do … end`). It is **not** the channel for slice/plugin
  enumeration — that role moves entirely into `slices do … end`.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Jido.Dsl.Agent]],
    untyped_extensions?: false,
    opt_schema: [
      extensions: [
        type: {:list, :any},
        default: [],
        doc:
          "Modules whose typed DSL section the host wants to call into " <>
            "(e.g. `Jido.Slices.AiReact` to unlock `react do … end`). " <>
            "Slice / plugin enumeration goes in `slices do … end`."
      ],
      middleware: [
        type: {:list, :any},
        default: [],
        doc:
          "Ordered list of middleware modules. Order is the wrap-chain " <>
            "order. Plugin modules with middleware behaviour also appear " <>
            "here for ordering, in addition to `slices do … end` for path."
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

  alias Jido.Agent
  alias Jido.Agent.State, as: StateHelper
  alias Jido.Directives
  alias Jido.Error
  alias Jido.Instruction

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
  @type directive :: Directives.t()

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
    user_middleware =
      opts
      |> Keyword.get(:middleware, [])
      |> List.wrap()

    quote location: :keep do
      @behaviour Jido.Agent

      alias Jido.Agent
      alias Jido.Agent.SliceUpdate
      alias Jido.Agent.State, as: AgentState
      alias Jido.Directives, as: AgentDirective
      alias Jido.Instruction
      alias Jido.Observe.Config, as: ObserveConfig
      alias Jido.Plugin.Requirements, as: PluginRequirements

      require OK

      @persist {:jido_user_middleware, unquote(Macro.escape(user_middleware))}
      @persist {:jido_instance_module, unquote(opts[:jido])}
      @persist {:default_slices_override, unquote(Macro.escape(opts[:default_slices]))}
    end
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
