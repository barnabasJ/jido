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
  See [ADR 0018](../adr/0018-tagged-tuple-return-shape.md).

  Key invariants:
  - On success the returned `agent` is **always complete** — no "apply
    directives" step needed.
  - On error the input agent is returned via the caller's error branch;
    successful prior instructions' slice changes vanish.
  - `directives` are **external effects only** — they never modify agent state.
  - `cmd/2` is a **pure function** — given same inputs, always same outputs.

  ## Action Formats

  `cmd/2` accepts actions in these forms:

  - `MyAction` - Action module with no params
  - `{MyAction, %{param: value}}` - Action with params
  - `%Instruction{}` - Full instruction struct
  - `[...]` - List of any of the above (processed in sequence)

  ## Directives

  Directives are effect descriptions for the runtime to interpret. They are
  **strictly outbound** - the agent never receives directives as input.

  Directives are bare structs (no tuple wrappers). Built-in directives
  (see `Jido.Agent.Directive`):

  - `%Directive.Emit{}` - Dispatch a signal via `Jido.Signal.Dispatch`
  - `%Directive.Error{}` - Observability marker for log channels (no longer
    produced by the cmd reducer; see ADR 0018)
  - `%Directive.Spawn{}` - Spawn a child process
  - `%Directive.Schedule{}` - Schedule a delayed message
  - `%Directive.RunInstruction{}` - Execute an instruction at runtime and route result to `cmd/2`
  - `%Directive.Stop{}` - Stop the agent process

  The Emit directive integrates with `Jido.Signal` for dispatch:

      # Emit with default dispatch config
      %Directive.Emit{signal: my_signal}

      # Emit to PubSub topic
      %Directive.Emit{signal: my_signal, dispatch: {:pubsub, topic: "events"}}

      # Emit to a specific process
      %Directive.Emit{signal: my_signal, dispatch: {:pid, target: pid}}

  External packages can define custom directive structs without modifying core.

  Directives never modify agent state — that's handled by the returned agent.

  ## Usage

  ### Defining an Agent Module

      defmodule MyAgent do
        use Jido.Agent,
          name: "my_agent",
          path: :domain,
          description: "My custom agent",
          schema: [
            status: [type: :atom, default: :idle],
            counter: [type: :integer, default: 0]
          ]
      end

  ### Working with Agents

      # Create a new agent (fully initialized including strategy state)
      agent = MyAgent.new()
      agent = MyAgent.new(id: "custom-id", state: %{counter: 10})
      # User-domain fields live under the agent's declared `path:` slice:
      #   agent.state.<path>.counter  #=> 10

      # Execute actions
      {:ok, agent, directives} = MyAgent.cmd(agent, MyAction)
      {:ok, agent, directives} = MyAgent.cmd(agent, {MyAction, %{value: 42}})
      {:ok, agent, directives} = MyAgent.cmd(agent, [Action1, Action2])

      # Multi-instruction batches are atomic; the first error aborts the rest
      {:error, %Jido.Error{}} = MyAgent.cmd(agent, [Action1, Failing, Action2])

      # Update state directly (flat attrs are auto-wrapped into the slice)
      {:ok, agent} = MyAgent.set(agent, %{status: :running})
      # agent.state.<path>.status  #=> :running

  ## State Schema Types

  Agent supports two schema formats for state validation:

  1. **NimbleOptions schemas** (familiar, legacy):
     ```elixir
     schema: [
       status: [type: :atom, default: :idle],
       counter: [type: :integer, default: 0]
     ]
     ```

  2. **Zoi schemas** (recommended for new code):
     ```elixir
     schema: Zoi.object(%{
       status: Zoi.atom() |> Zoi.default(:idle),
       counter: Zoi.integer() |> Zoi.default(0)
     })
     ```

  Both are handled transparently by the Agent module.

  ## Pure Functional Design

  The Agent struct is immutable. All operations return new agent structs.
  Server/OTP integration is handled separately by `Jido.AgentServer`.
  """

  alias Jido.Action.Schema
  alias Jido.Agent
  alias Jido.Agent.Directive
  alias Jido.Agent.State, as: StateHelper
  alias Jido.Error
  alias Jido.Instruction
  alias Jido.Plugin.Instance, as: PluginInstance
  alias Jido.Plugin.Requirements, as: PluginRequirements

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
  # See Jido.Agent.Directive for structured payload modules
  @type directive :: Directive.t()

  @type agent_result :: {:ok, t()} | {:error, Error.t()}
  @type cmd_result :: {:ok, t(), [directive()]} | {:error, term()}

  @agent_config_schema Zoi.object(
                         %{
                           name:
                             Zoi.string(
                               description:
                                 "The name of the Agent. Must contain only letters, numbers, and underscores."
                             )
                             |> Zoi.refine({Jido.Util, :validate_name, []}),
                           description:
                             Zoi.string(description: "A description of what the Agent does.")
                             |> Zoi.optional(),
                           category:
                             Zoi.string(description: "The category of the Agent.")
                             |> Zoi.optional(),
                           tags:
                             Zoi.list(Zoi.string(), description: "Tags")
                             |> Zoi.default([]),
                           vsn:
                             Zoi.string(description: "Version")
                             |> Zoi.optional(),
                           schema:
                             Zoi.any(
                               description:
                                 "NimbleOptions or Zoi schema for validating the Agent's state."
                             )
                             |> Zoi.refine({Schema, :validate_config_schema, []})
                             |> Zoi.default([]),
                           plugins:
                             Zoi.list(Zoi.any(),
                               description: "Plugin modules or {module, config} tuples"
                             )
                             |> Zoi.default([]),
                           middleware:
                             Zoi.list(Zoi.any(),
                               description:
                                 "Middleware modules or {module, opts_map} tuples for the on_signal/4 chain"
                             )
                             |> Zoi.default([]),
                           signal_routes:
                             Zoi.list(Zoi.any(),
                               description:
                                 "Compile-time signal route table. Each route maps signal type/pattern to an action target."
                             )
                             |> Zoi.default([]),
                           default_plugins:
                             Zoi.any(
                               description:
                                 "Override default plugins. false to disable all, or map of %{path => false | Module | {Module, config}}"
                             )
                             |> Zoi.optional(),
                           schedules:
                             Zoi.list(Zoi.any(),
                               description:
                                 "Declarative cron schedules as {cron_expr, signal_type} or {cron_expr, signal_type, opts}"
                             )
                             |> Zoi.default([]),
                           jido:
                             Zoi.atom(
                               description:
                                 "Jido instance module for resolving default plugins at compile time"
                             )
                             |> Zoi.optional(),
                           path:
                             Zoi.atom(
                               description:
                                 "Required atom slice key where the agent's user-domain state lives under `agent.state`. Actions that don't declare their own `path:` operate on this same slice. See ADR 0014."
                             )
                         },
                         coerce: true
                       )

  @doc false
  @spec config_schema() :: Zoi.schema()
  def config_schema, do: @agent_config_schema

  # Callbacks

  @doc """
  Returns signal routes for this agent.

  Routes map signal types to action modules. AgentServer uses these routes
  to map incoming signals to actions for execution via cmd/2.

  ## Route Formats

  - `{path, ActionModule}` - Simple mapping (priority 0)
  - `{path, ActionModule, priority}` - With priority
  - `{path, {ActionModule, %{static: params}}}` - With static params
  - `{path, match_fn, ActionModule}` - With pattern matching
  - `{path, match_fn, ActionModule, priority}` - Full spec

  ## Context

  The context map currently contains:
  - `agent_module` - The agent module

  ## Examples

      use Jido.Agent,
        name: "my_agent",
        signal_routes: [
          {"user.created", HandleUserCreatedAction},
          {"counter.increment", IncrementAction},
          {"payment.*", fn s -> s.data.amount > 100 end, LargePaymentAction, 10}
        ]
  """
  @callback signal_routes() :: [Jido.Signal.Router.route_spec()]
  @callback signal_routes(ctx :: map()) :: [Jido.Signal.Router.route_spec()]

  @doc """
  Optional persistence hooks. When implemented, `Jido.Persist.hibernate/2`
  uses these to serialize/deserialize the agent. If absent, defaults are used.
  """
  @callback checkpoint(agent :: t(), ctx :: map()) :: {:ok, map()} | {:error, term()}
  @callback restore(checkpoint :: map(), ctx :: map()) :: {:ok, t()} | {:error, term()}

  @optional_callbacks [
    signal_routes: 0,
    signal_routes: 1,
    checkpoint: 2,
    restore: 2
  ]

  # Helper functions that generate quoted code for the __using__ macro.
  # This approach reduces the size of the main quote block to avoid
  # "long quote blocks" and "nested too deep" Credo warnings.

  @doc false
  @spec __quoted_module_setup__() :: Macro.t()
  def __quoted_module_setup__ do
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
    end
  end

  @doc false
  @spec __quoted_basic_accessors__() :: Macro.t()
  def __quoted_basic_accessors__ do
    quote location: :keep do
      @doc "Returns the agent's name."
      @spec name() :: String.t()
      def name, do: @validated_opts.name

      @doc "Returns the agent's description."
      @spec description() :: String.t() | nil
      def description, do: @validated_opts[:description]

      @doc "Returns the agent's category."
      @spec category() :: String.t() | nil
      def category, do: @validated_opts[:category]

      @doc "Returns the agent's tags."
      @spec tags() :: [String.t()]
      def tags, do: @validated_opts[:tags] || []

      @doc "Returns the agent's version."
      @spec vsn() :: String.t() | nil
      def vsn, do: @validated_opts[:vsn]

      @doc """
      Returns the atom slice key where the agent's user-domain state lives.

      Required at compile time (ADR 0014). Schema defaults are seeded under
      `agent.state[path]` and actions that declare a matching `path:` receive
      just that slice as the `slice` argument of `run/4`.
      """
      @spec path() :: atom()
      def path, do: @validated_opts.path

      @doc "Returns the merged schema (base + plugin schemas)."
      @spec schema() :: Zoi.schema() | keyword()
      def schema, do: @merged_schema

      @doc """
      Returns the middleware modules attached to this agent.

      Each entry is either a bare module or `{module, opts_map}`. The list
      is verbatim from the `middleware:` compile-time option; AgentServer
      composes these into the on_signal/4 chain at init time.
      """
      @spec middleware() :: [module() | {module(), map()}]
      def middleware, do: @validated_opts[:middleware] || []

      @doc false
      @spec __agent_metadata__() :: map()
      def __agent_metadata__ do
        %{
          module: __MODULE__,
          name: name(),
          description: description(),
          category: category(),
          tags: tags(),
          vsn: vsn(),
          actions: actions(),
          schema: schema()
        }
      end
    end
  end

  @doc false
  @spec __quoted_plugin_accessors__() :: Macro.t()
  def __quoted_plugin_accessors__ do
    basic_plugin_accessors = __quoted_basic_plugin_accessors__()
    computed_plugin_accessors = __quoted_computed_plugin_accessors__()

    quote location: :keep do
      unquote(basic_plugin_accessors)
      unquote(computed_plugin_accessors)
    end
  end

  defp __quoted_basic_plugin_accessors__ do
    quote location: :keep do
      @doc """
      Returns the list of plugin modules attached to this agent (deduplicated).

      For multi-instance plugins, the module appears once regardless of how many
      instances are mounted.

      ## Example

          MyAgent.plugins()
          # => [MyApp.SlackPlugin, MyApp.OpenAIPlugin]
      """
      @spec plugins() :: [module()]
      def plugins do
        @plugin_instances
        |> Enum.map(& &1.module)
        |> Enum.uniq()
      end

      @doc "Returns the list of plugin specs attached to this agent."
      @spec plugin_specs() :: [Jido.Plugin.Spec.t()]
      def plugin_specs, do: @plugin_specs

      @doc "Returns the list of plugin instances attached to this agent."
      @spec plugin_instances() :: [Jido.Plugin.Instance.t()]
      def plugin_instances, do: @plugin_instances

      @doc "Returns the list of actions from all attached plugins."
      @spec actions() :: [module()]
      def actions, do: @plugin_actions
    end
  end

  defp __quoted_computed_plugin_accessors__ do
    quote location: :keep do
      @doc """
      Returns the union of all capabilities from all mounted plugin instances.

      Capabilities are atoms describing what the agent can do based on its
      mounted plugins.

      ## Example

          MyAgent.capabilities()
          # => [:messaging, :channel_management, :chat, :embeddings]
      """
      @spec capabilities() :: [atom()]
      def capabilities do
        @plugin_instances
        |> Enum.flat_map(fn instance -> instance.manifest.capabilities || [] end)
        |> Enum.uniq()
      end

      @doc """
      Returns all expanded route signal types from plugin routes.

      These are the fully-prefixed signal types that the agent can handle.

      ## Example

          MyAgent.signal_types()
          # => ["slack.post", "slack.channels.list", "openai.chat"]
      """
      @spec signal_types() :: [String.t()]
      def signal_types do
        @validated_plugin_routes
        |> Enum.map(fn {signal_type, _action, _priority} -> signal_type end)
      end

      @doc "Returns the expanded and validated plugin routes."
      @spec plugin_routes() :: [{String.t(), module(), integer()}]
      def plugin_routes, do: @validated_plugin_routes

      @doc "Returns the expanded plugin and agent schedules."
      @spec plugin_schedules() :: [
              Jido.Plugin.Schedules.schedule_spec() | Jido.Agent.Schedules.schedule_spec()
            ]
      def plugin_schedules, do: @expanded_plugin_schedules ++ @expanded_agent_schedules
    end
  end

  @doc false
  @spec __quoted_plugin_config_accessors__() :: Macro.t()
  def __quoted_plugin_config_accessors__ do
    plugin_config_public = __quoted_plugin_config_public__()
    plugin_config_helpers = __quoted_plugin_config_helpers__()
    plugin_state_public = __quoted_plugin_state_public__()
    plugin_state_helpers = __quoted_plugin_state_helpers__()

    quote location: :keep do
      unquote(plugin_config_public)
      unquote(plugin_config_helpers)
      unquote(plugin_state_public)
      unquote(plugin_state_helpers)
    end
  end

  defp __quoted_plugin_config_public__ do
    quote location: :keep do
      @doc """
      Returns the configuration for a specific plugin.

      Accepts either a module or a `{module, as_alias}` tuple for multi-instance plugins.
      """
      @spec plugin_config(module() | {module(), atom()}) :: map() | nil
      def plugin_config(plugin_mod) when is_atom(plugin_mod) do
        __find_plugin_config_by_module__(plugin_mod)
      end

      def plugin_config({plugin_mod, as_alias}) when is_atom(plugin_mod) and is_atom(as_alias) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod and &1.as == as_alias)) do
          nil -> nil
          instance -> instance.config
        end
      end
    end
  end

  defp __quoted_plugin_config_helpers__ do
    quote location: :keep do
      defp __find_plugin_config_by_module__(plugin_mod) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod and is_nil(&1.as))) do
          nil -> __find_plugin_config_fallback__(plugin_mod)
          instance -> instance.config
        end
      end

      defp __find_plugin_config_fallback__(plugin_mod) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod)) do
          nil -> nil
          instance -> instance.config
        end
      end
    end
  end

  defp __quoted_plugin_state_public__ do
    quote location: :keep do
      @doc """
      Returns the state slice for a specific plugin.

      Accepts either a module or a `{module, as_alias}` tuple for multi-instance plugins.
      """
      @spec plugin_state(Agent.t(), module() | {module(), atom()}) :: map() | nil
      def plugin_state(agent, plugin_mod) when is_atom(plugin_mod) do
        __find_plugin_state_by_module__(agent, plugin_mod)
      end

      def plugin_state(agent, {plugin_mod, as_alias})
          when is_atom(plugin_mod) and is_atom(as_alias) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod and &1.as == as_alias)) do
          nil -> nil
          instance -> Map.get(agent.state, instance.path)
        end
      end
    end
  end

  defp __quoted_plugin_state_helpers__ do
    quote location: :keep do
      defp __find_plugin_state_by_module__(agent, plugin_mod) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod and is_nil(&1.as))) do
          nil -> __find_plugin_state_fallback__(agent, plugin_mod)
          instance -> Map.get(agent.state, instance.path)
        end
      end

      defp __find_plugin_state_fallback__(agent, plugin_mod) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod)) do
          nil -> nil
          instance -> Map.get(agent.state, instance.path)
        end
      end
    end
  end

  @doc false
  @spec __quoted_new_function__() :: Macro.t()
  def __quoted_new_function__ do
    new_fn = __quoted_new_fn_definition__()

    quote location: :keep do
      unquote(new_fn)
    end
  end

  defp __quoted_new_fn_definition__ do
    quote location: :keep do
      @doc """
      Creates a new agent with optional initial state.

      ## Examples

          agent = #{inspect(__MODULE__)}.new()
          agent = #{inspect(__MODULE__)}.new(id: "custom-id")

          # Flat state is auto-wrapped into the agent's declared `path:` slice
          agent = #{inspect(__MODULE__)}.new(state: %{counter: 10})
          # agent.state[path()].counter  #=> 10
      """
      @spec new(keyword() | map()) :: Agent.t()
      def new(opts \\ []) do
        opts = if is_list(opts), do: Map.new(opts), else: opts

        initial_state = __build_initial_state__(opts)

        id =
          case opts[:id] do
            nil -> Jido.Util.generate_id()
            "" -> Jido.Util.generate_id()
            id when is_binary(id) -> id
            other -> to_string(other)
          end

        %Agent{
          id: id,
          agent_module: __MODULE__,
          name: name(),
          description: description(),
          category: category(),
          tags: tags(),
          vsn: vsn(),
          schema: schema(),
          state: initial_state
        }
      end

      # Seeds the initial agent state from declared slices. The agent's own
      # slice (under `path()`) gets schema defaults plus user-supplied state.
      # Each declared plugin/slice gets `(plugin_config + user-supplied
      # state_for_path)` shallow-merged, then validated through the slice's
      # Zoi schema if present. See ADR 0014 (no deep-merge, no mount/2).
      defp __build_initial_state__(opts) do
        user_state = __wrap_user_state__(opts[:state] || %{})

        own_path = path()
        own_user = Map.get(user_state, own_path, %{})
        own_slice = Jido.Agent.__seed_own_slice__(@validated_opts[:schema], own_user)

        plugin_slices =
          Enum.reduce(@plugin_instances, %{}, fn instance, acc ->
            user_for_slice = Map.get(user_state, instance.path) || %{}
            merged_input = Map.merge(instance.config || %{}, user_for_slice)
            slice = Jido.Agent.__seed_plugin_slice__(instance.module, merged_input)
            Map.put(acc, instance.path, slice)
          end)

        # Drop slice-owned keys from user_state, preserve everything else as
        # top-level scratch state (state-ops can target it via SetPath/DeletePath/...).
        known_slice_paths = [own_path | @plugin_paths]
        leftover = Map.drop(user_state, known_slice_paths)

        leftover
        |> Map.merge(plugin_slices)
        |> Map.put(own_path, own_slice)
      end

      defp __wrap_user_state__(%{} = user_state) do
        known_slices = [path() | @plugin_paths]

        cond do
          map_size(user_state) == 0 ->
            user_state

          Enum.any?(Map.keys(user_state), fn k -> k in known_slices end) ->
            # User passed an explicit slice layout — take it as-is
            user_state

          true ->
            # Flat shape — wrap under the agent's slice
            %{path() => user_state}
        end
      end
    end
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
    case plugin_module.schema() do
      nil ->
        if map_size(merged_input) == 0, do: nil, else: merged_input

      schema ->
        case Zoi.parse(schema, merged_input) do
          {:ok, validated} ->
            validated

          {:error, errors} ->
            raise Jido.Agent.SliceValidationError,
              path: plugin_module.path(),
              module: plugin_module,
              errors: errors
        end
    end
  end

  @doc false
  @spec __quoted_cmd_function__() :: Macro.t()
  def __quoted_cmd_function__ do
    quote location: :keep do
      @doc """
      Execute actions against the agent. Pure:
      `(agent, action) -> {:ok, agent, [directive]} | {:error, reason}`.

      Actions modify state; directives are external effects. The reducer runs
      each instruction by handing the action its declared slice (per `path:`)
      and writing the returned slice back wholesale (no deep-merge — every
      action returns the full new slice, see ADR 0014).

      Multi-instruction `cmd` is all-or-nothing: the first `{:error, _}` halts
      the batch and the input agent is returned through the caller's error
      branch; successful prior instructions' slice changes vanish.
      See [ADR 0018](../adr/0018-tagged-tuple-return-shape.md).

      ## Action Formats

        * `MyAction` - Action module with no params
        * `{MyAction, %{param: 1}}` - Action with params
        * `{MyAction, %{param: 1}, %{context: data}}` - Action with params and context
        * `{MyAction, %{param: 1}, %{}, [timeout: 1000]}` - Action with opts
        * `%Instruction{}` - Full instruction struct
        * `[...]` - List of any of the above (processed in sequence)

      ## Options

      The optional third argument `opts` is a keyword list merged into all instructions:

        * `:timeout` - Maximum time (in ms) for each action to complete
        * `:max_retries` - Maximum retry attempts on failure
        * `:backoff` - Initial backoff time in ms (doubles with each retry)

      ## Examples

          {:ok, agent, directives} = #{inspect(__MODULE__)}.cmd(agent, MyAction)
          {:ok, agent, directives} = #{inspect(__MODULE__)}.cmd(agent, {MyAction, %{value: 42}})
          {:ok, agent, directives} = #{inspect(__MODULE__)}.cmd(agent, [Action1, Action2])
          {:error, %Jido.Error{}} = #{inspect(__MODULE__)}.cmd(agent, FailingAction)

          # With per-call options (merged into all instructions)
          {:ok, agent, directives} =
            #{inspect(__MODULE__)}.cmd(agent, MyAction, timeout: 5000)
      """
      @spec cmd(Agent.t(), Agent.action()) :: Agent.cmd_result()
      def cmd(%Agent{} = agent, action), do: cmd(agent, action, [])

      @spec cmd(Agent.t(), Agent.action(), keyword()) :: Agent.cmd_result()
      def cmd(%Agent{} = agent, action, opts) when is_list(opts) do
        {ctx, opts} = Keyword.pop(opts, :ctx, %{})
        {input_signal, instruction_opts} = Keyword.pop(opts, :input_signal)

        ctx =
          ctx
          |> Map.put_new(:agent_id, agent.id)

        jido_instance = Map.get(ctx, :jido_instance) || Map.get(ctx, :jido)

        base_context =
          case input_signal do
            nil -> %{state: agent.state, ctx: ctx}
            signal -> %{state: agent.state, signal: signal, ctx: ctx}
          end

        case Instruction.normalize(action, base_context, instruction_opts) do
          {:ok, instructions} ->
            __run_cmd_loop__(agent, instructions, jido_instance)

          {:error, reason} ->
            {:error, Jido.Error.validation_error("Invalid action", %{reason: reason})}
        end
      end

      # All-or-nothing batch: the first {:error, _} halts the batch, the
      # original agent is returned via the caller's error branch, and the
      # accumulated directives are discarded.
      defp __run_cmd_loop__(initial_agent, instructions, jido_instance) do
        Enum.reduce_while(instructions, {:ok, initial_agent, []}, fn
          instruction, {:ok, acc_agent, acc_dirs} ->
            case __run_instruction__(acc_agent, instruction, jido_instance) do
              {:ok, new_agent, new_dirs} ->
                {:cont, {:ok, new_agent, acc_dirs ++ List.wrap(new_dirs)}}

              {:error, _reason} = err ->
                {:halt, err}
            end
        end)
      end

      defp __run_instruction__(agent, %Instruction{action: action} = instruction, jido_instance) do
        slice_path = __resolve_slice_path__(action)
        scoped_state = Map.get(agent.state, slice_path, %{})

        instruction = %{
          instruction
          | context:
              instruction.context
              |> Map.put(:state, scoped_state)
              |> Map.put(:agent, agent)
              |> Map.put(:agent_server_pid, self())
        }

        exec_opts = ObserveConfig.action_exec_opts(jido_instance, instruction.opts)

        case Jido.Exec.run(%{instruction | opts: exec_opts}) do
          {:ok, new_slice, effects} when is_map(new_slice) ->
            {new_agent, dirs} =
              __apply_slice_result__(agent, slice_path, new_slice, List.wrap(effects))

            {:ok, new_agent, dirs}

          {:error, reason} ->
            {:error, Jido.Error.from_term(reason)}
        end
      end

      # Every action declares `path/0` (per C0). If it returns a non-nil atom,
      # use it; otherwise fall back to the agent's domain slice. We
      # `Code.ensure_loaded/1` first because `function_exported?/3` would
      # spuriously say `false` for a module that hasn't been resolved yet —
      # that yielded a non-deterministic test failure where the very first
      # call to a fresh action targeted the wrong slice.
      defp __resolve_slice_path__(action)
           when is_atom(action) and not is_nil(action) do
        Code.ensure_loaded(action)

        case action.path() do
          p when is_atom(p) and not is_nil(p) -> p
          _ -> path()
        end
      rescue
        UndefinedFunctionError -> path()
      end

      defp __resolve_slice_path__(_action), do: path()

      defp __apply_slice_result__(agent, _slice_path, %SliceUpdate{slices: slices}, effects) do
        new_state =
          Enum.reduce(slices, agent.state, fn {path, value}, acc ->
            Map.put(acc, path, value)
          end)

        {%{agent | state: new_state}, effects}
      end

      defp __apply_slice_result__(agent, slice_path, new_slice, effects) when is_map(new_slice) do
        new_state = Map.put(agent.state, slice_path, new_slice)
        {%{agent | state: new_state}, effects}
      end
    end
  end

  @doc false
  @spec __quoted_utility_functions__() :: Macro.t()
  def __quoted_utility_functions__ do
    quote location: :keep do
      @doc """
      Updates the agent's state by merging new attributes.

      Uses deep merge semantics - nested maps are merged recursively. Flat
      attrs are auto-wrapped into the agent's declared `path:` slice.

      ## Examples

          {:ok, agent} = #{inspect(__MODULE__)}.set(agent, %{status: :running})
          # agent.state.<path>.status  #=> :running

          {:ok, agent} = #{inspect(__MODULE__)}.set(agent, counter: 5)
          # agent.state.<path>.counter  #=> 5
      """
      @spec set(Agent.t(), map() | keyword()) :: Agent.agent_result()
      def set(%Agent{} = agent, attrs) do
        # Same auto-wrap as __build_initial_state__: flat attrs become "my
        # domain slice"; explicit slice layout is taken verbatim (ADR 0007).
        wrapped = __wrap_user_state__(Map.new(attrs))
        new_state = AgentState.merge(agent.state, wrapped)
        OK.success(%{agent | state: new_state})
      end

      @doc """
      Validates the agent's state against its schema.

      ## Options
        * `:strict` - When true, only schema-defined fields are kept (default: false)

      ## Examples

          {:ok, agent} = #{inspect(__MODULE__)}.validate(agent)
          {:ok, agent} = #{inspect(__MODULE__)}.validate(agent, strict: true)
      """
      @spec validate(Agent.t(), keyword()) :: Agent.agent_result()
      def validate(%Agent{} = agent, opts \\ []) do
        case AgentState.validate(agent.state, agent.schema, opts) do
          {:ok, validated_state} ->
            OK.success(%{agent | state: validated_state})

          {:error, reason} ->
            Jido.Error.validation_error("State validation failed", %{reason: reason})
            |> OK.failure()
        end
      end
    end
  end

  @doc false
  @spec __quoted_callbacks__() :: Macro.t()
  def __quoted_callbacks__ do
    routes = __quoted_callback_routes__()
    overridables = __quoted_callback_overridables__()

    quote location: :keep do
      unquote(routes)
      unquote(overridables)
    end
  end

  defp __quoted_callback_routes__ do
    quote location: :keep do
      @impl true
      @spec signal_routes() :: list()
      def signal_routes, do: @expanded_signal_routes

      @impl true
      @spec signal_routes(map()) :: list()
      def signal_routes(_ctx), do: signal_routes()
    end
  end

  defp __quoted_callback_overridables__ do
    quote location: :keep do
      defoverridable signal_routes: 0,
                     signal_routes: 1,
                     name: 0,
                     description: 0,
                     category: 0,
                     tags: 0,
                     vsn: 0,
                     schema: 0,
                     plugins: 0,
                     plugin_specs: 0,
                     plugin_instances: 0,
                     actions: 0,
                     capabilities: 0,
                     signal_types: 0,
                     plugin_config: 1,
                     plugin_state: 2,
                     plugin_routes: 0,
                     plugin_schedules: 0
    end
  end

  defmacro __using__(opts) do
    # Get the quoted blocks from helper functions
    module_setup = Agent.__quoted_module_setup__()
    basic_accessors = Agent.__quoted_basic_accessors__()
    plugin_accessors = Agent.__quoted_plugin_accessors__()
    plugin_config_accessors = Agent.__quoted_plugin_config_accessors__()
    new_function = Agent.__quoted_new_function__()
    cmd_function = Agent.__quoted_cmd_function__()
    utility_functions = Agent.__quoted_utility_functions__()
    callbacks = Agent.__quoted_callbacks__()

    # Build compile-time validation and module attributes as a separate smaller block
    compile_time_setup =
      quote location: :keep do
        # Validate config at compile time
        @validated_opts (case Zoi.parse(Agent.config_schema(), Map.new(unquote(opts))) do
                           {:ok, validated} ->
                             validated

                           {:error, errors} ->
                             message =
                               "Invalid Agent configuration for #{inspect(__MODULE__)}: #{inspect(errors)}"

                             raise CompileError,
                               description: message,
                               file: __ENV__.file,
                               line: __ENV__.line
                         end)

        @expanded_signal_routes Jido.Agent.expand_and_eval_literal_option(
                                  @validated_opts[:signal_routes] || [],
                                  __ENV__
                                )

        @default_plugin_list Jido.Agent.__resolve_default_plugins__(@validated_opts)
        @all_plugin_decls @default_plugin_list ++ (@validated_opts[:plugins] || [])
        @plugin_instances Jido.Agent.__normalize_plugin_instances__(@all_plugin_decls)

        @singleton_alias_violations @plugin_instances
                                    |> Enum.filter(fn inst ->
                                      inst.module.singleton?() and inst.as != nil
                                    end)
        if @singleton_alias_violations != [] do
          modules =
            Enum.map(@singleton_alias_violations, & &1.module) |> Enum.map(&inspect/1)

          raise CompileError,
            description: "Cannot alias singleton plugins: #{Enum.join(modules, ", ")}",
            file: __ENV__.file,
            line: __ENV__.line
        end

        @singleton_modules @plugin_instances
                           |> Enum.filter(fn inst -> inst.module.singleton?() end)
                           |> Enum.map(& &1.module)
        @duplicate_singletons @singleton_modules -- Enum.uniq(@singleton_modules)
        if @duplicate_singletons != [] do
          raise CompileError,
            description:
              "Duplicate singleton plugins: #{inspect(Enum.uniq(@duplicate_singletons))}",
            file: __ENV__.file,
            line: __ENV__.line
        end

        # Build plugin specs from instances (with the instance path).
        @plugin_specs Enum.map(@plugin_instances, fn instance ->
                        spec = instance.module.plugin_spec(instance.config)
                        %{spec | path: instance.path}
                      end)

        # Validate unique slice paths across the agent and every declared
        # plugin. Path = agent.path() ++ each plugin.path(). A duplicate
        # raises Jido.Agent.PathConflictError at Agent.new/1 today, but we
        # fail fast at compile time when the conflict is statically known.
        @plugin_paths Enum.map(@plugin_instances, & &1.path)
        @all_slice_paths [@validated_opts.path | @plugin_paths]
        @duplicate_paths @all_slice_paths -- Enum.uniq(@all_slice_paths)
        if @duplicate_paths != [] do
          raise CompileError,
            description: "Duplicate slice paths: #{inspect(Enum.uniq(@duplicate_paths))}",
            file: __ENV__.file,
            line: __ENV__.line
        end

        # Merge schemas: base schema + nested plugin schemas
        @merged_schema Jido.Agent.Schema.merge_with_plugins(
                         @validated_opts[:schema],
                         @plugin_specs
                       )

        # Aggregate actions from plugins
        @plugin_actions @plugin_specs |> Enum.flat_map(& &1.actions) |> Enum.uniq()

        # Expand routes from all plugin instances
        @expanded_plugin_routes Enum.flat_map(
                                  @plugin_instances,
                                  &Jido.Plugin.Routes.expand_routes/1
                                )

        # Expand schedules from all plugin instances
        @expanded_plugin_schedules Enum.flat_map(
                                     @plugin_instances,
                                     &Jido.Plugin.Schedules.expand_schedules/1
                                   )

        # Generate routes for schedule signal types (low priority)
        @schedule_routes Enum.flat_map(
                           @plugin_instances,
                           &Jido.Plugin.Schedules.schedule_routes/1
                         )

        # Expand agent-level schedules from the `schedules:` option
        @expanded_agent_schedules Jido.Agent.Schedules.expand_schedules(
                                    @validated_opts[:schedules] || [],
                                    @validated_opts[:name]
                                  )

        # Generate routes for agent schedule signal types
        @agent_schedule_routes Jido.Agent.Schedules.schedule_routes(@expanded_agent_schedules)

        # Combine routes and schedule routes for conflict detection
        @all_plugin_routes @expanded_plugin_routes ++ @schedule_routes ++ @agent_schedule_routes

        @plugin_routes_result Jido.Plugin.Routes.detect_conflicts(@all_plugin_routes)
        case @plugin_routes_result do
          {:error, conflicts} ->
            conflict_list = Enum.join(conflicts, "\n  - ")

            raise CompileError,
              description: "Route conflicts detected:\n  - #{conflict_list}",
              file: __ENV__.file,
              line: __ENV__.line

          {:ok, _routes} ->
            :ok
        end

        @validated_plugin_routes elem(@plugin_routes_result, 1)

        # Validate plugin requirements at compile time
        @plugin_config_map Enum.reduce(@plugin_instances, %{}, fn instance, acc ->
                             Map.put(acc, instance.path, instance.config)
                           end)
        @requirements_result Jido.Plugin.Requirements.validate_all_requirements(
                               @plugin_instances,
                               @plugin_config_map
                             )
        case @requirements_result do
          {:error, missing_by_plugin} ->
            error_msg = PluginRequirements.format_error(missing_by_plugin)

            raise CompileError,
              description: error_msg,
              file: __ENV__.file,
              line: __ENV__.line

          {:ok, :valid} ->
            :ok
        end
      end

    # Combine all blocks using unquote
    quote location: :keep do
      unquote(module_setup)
      unquote(compile_time_setup)
      unquote(basic_accessors)
      unquote(plugin_accessors)
      unquote(plugin_config_accessors)
      unquote(new_function)
      unquote(cmd_function)
      unquote(utility_functions)
      unquote(callbacks)
    end
  end

  @doc false
  @spec __normalize_plugin_instances__([module() | {module(), map()}]) :: [PluginInstance.t()]
  def __normalize_plugin_instances__(plugins) do
    Enum.map(plugins, &__validate_and_create_plugin_instance__/1)
  end

  @doc false
  @spec __resolve_default_plugins__(map()) :: [module() | {module(), map()}]
  def __resolve_default_plugins__(agent_opts) do
    jido_module = agent_opts[:jido]

    base_defaults =
      if jido_module != nil and function_exported?(jido_module, :__default_plugins__, 0) do
        jido_module.__default_plugins__()
      else
        Jido.Agent.DefaultPlugins.package_defaults()
      end

    Jido.Agent.DefaultPlugins.apply_agent_overrides(base_defaults, agent_opts[:default_plugins])
  end

  defp __validate_and_create_plugin_instance__(plugin_decl) do
    mod = __extract_plugin_module__(plugin_decl)
    __validate_plugin_module__(mod)
    PluginInstance.new(plugin_decl)
  end

  defp __extract_plugin_module__(m) when is_atom(m), do: m
  defp __extract_plugin_module__({m, _}), do: m

  defp __validate_plugin_module__(mod) do
    case Code.ensure_compiled(mod) do
      {:module, _} -> __validate_plugin_behaviour__(mod)
      {:error, reason} -> __raise_plugin_compile_error__(mod, reason)
    end
  end

  defp __validate_plugin_behaviour__(mod) do
    unless function_exported?(mod, :plugin_spec, 1) do
      raise CompileError,
        description: "#{inspect(mod)} does not implement Jido.Plugin (missing plugin_spec/1)"
    end
  end

  defp __raise_plugin_compile_error__(mod, reason) do
    raise CompileError,
      description: "Plugin #{inspect(mod)} could not be compiled: #{inspect(reason)}"
  end

  # Base module functions (for direct use without `use`)

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
