defmodule Jido.Dsl.Agent.Transformers.GenerateAccessors do
  @moduledoc """
  Final transformer in the agent DSL pipeline. Reads everything previous
  transformers have persisted into DSL state and emits, into the user's
  agent module:

    * The legacy compile-time module attributes (`@validated_opts`,
      `@plugin_instances`, `@expanded_signal_routes`, …) so any reader
      that still uses `@…` keeps working.
    * The full public accessor surface — `name/0`, `description/0`,
      `path/0`, `schema/0`, `plugins/0`, `slices/0`, `middleware/0`,
      `actions/0`, `signal_routes/0`, etc.
    * The `defoverridable` block so user agents can still override any
      accessor.
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
        require OK

        unquote(quoted_module_attributes(state))
        unquote(quoted_basic_accessors())
        unquote(quoted_plugin_accessors())
        unquote(quoted_plugin_config_accessors())
        unquote(quoted_new_function())
        unquote(quoted_cmd_function())
        unquote(quoted_utility_functions())
        unquote(quoted_callbacks_and_overridables())
      end

    {:ok, Transformer.eval(dsl_state, [], block)}
  end

  defp collect_state(dsl_state) do
    %{
      validated_opts: build_validated_opts(dsl_state),
      expanded_signal_routes: Transformer.get_persisted(dsl_state, :expanded_signal_routes, []),
      plugin_instances: Transformer.get_persisted(dsl_state, :plugin_instances, []),
      slice_instances: Transformer.get_persisted(dsl_state, :slice_instances, []),
      plugin_specs: Transformer.get_persisted(dsl_state, :plugin_specs, []),
      plugin_paths: Transformer.get_persisted(dsl_state, :plugin_paths, []),
      slice_paths: Transformer.get_persisted(dsl_state, :slice_paths, []),
      plugin_actions: Transformer.get_persisted(dsl_state, :plugin_actions, []),
      merged_schema: Transformer.get_persisted(dsl_state, :merged_schema, []),
      validated_plugin_routes: Transformer.get_persisted(dsl_state, :validated_plugin_routes, []),
      expanded_plugin_schedules:
        Transformer.get_persisted(dsl_state, :expanded_plugin_schedules, []),
      expanded_agent_schedules:
        Transformer.get_persisted(dsl_state, :expanded_agent_schedules, [])
    }
  end

  defp build_validated_opts(dsl_state) do
    %{
      name: Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :name),
      description: Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :description),
      category: Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :category),
      tags: Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :tags) || [],
      vsn: Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :vsn),
      path: Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :path),
      schema: Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :schema, []),
      middleware: Transformer.get_persisted(dsl_state, :middleware_list, [])
    }
  end

  defp quoted_module_attributes(state) do
    quote do
      @validated_opts unquote(Macro.escape(state.validated_opts))
      @expanded_signal_routes unquote(Macro.escape(state.expanded_signal_routes))
      @plugin_instances unquote(Macro.escape(state.plugin_instances))
      @slice_instances unquote(Macro.escape(state.slice_instances))
      @plugin_specs unquote(Macro.escape(state.plugin_specs))
      @plugin_paths unquote(Macro.escape(state.plugin_paths))
      @slice_paths unquote(Macro.escape(state.slice_paths))
      @plugin_actions unquote(Macro.escape(state.plugin_actions))
      @merged_schema unquote(Macro.escape(state.merged_schema))
      @validated_plugin_routes unquote(Macro.escape(state.validated_plugin_routes))
      @expanded_plugin_schedules unquote(Macro.escape(state.expanded_plugin_schedules))
      @expanded_agent_schedules unquote(Macro.escape(state.expanded_agent_schedules))
    end
  end

  defp quoted_basic_accessors do
    quote do
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

      @doc "Returns the atom slice key where the agent's user-domain state lives."
      @spec path() :: atom()
      def path, do: @validated_opts.path

      @doc "Returns the merged schema (base + plugin schemas)."
      @spec schema() :: term()
      def schema, do: @merged_schema

      @doc "Returns the middleware modules attached to this agent."
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

  defp quoted_plugin_accessors do
    quote do
      @doc "Returns the list of plugin modules attached to this agent (deduplicated)."
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

      @doc "Returns the list of bare-slice modules attached to this agent."
      @spec slices() :: [module()]
      def slices do
        @slice_instances
        |> Enum.map(& &1.module)
        |> Enum.uniq()
      end

      @doc "Returns the list of slice instances attached to this agent."
      @spec slice_instances() :: [Jido.Slice.Instance.t()]
      def slice_instances, do: @slice_instances

      @doc "Returns the list of actions from all attached plugins and slices."
      @spec actions() :: [module()]
      def actions, do: @plugin_actions

      @doc "Returns the union of all capabilities from all mounted instances."
      @spec capabilities() :: [atom()]
      def capabilities do
        (@plugin_instances ++ @slice_instances)
        |> Enum.flat_map(fn instance -> instance.manifest.capabilities || [] end)
        |> Enum.uniq()
      end

      @doc "Returns all expanded route signal types from plugin routes."
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

  defp quoted_plugin_config_accessors do
    quote do
      @doc "Returns the configuration for a specific plugin."
      @spec plugin_config(module() | {module(), atom()}) :: map() | nil
      def plugin_config(plugin_mod) when is_atom(plugin_mod) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod and is_nil(&1.as))) do
          nil ->
            case Enum.find(@plugin_instances, &(&1.module == plugin_mod)) do
              nil -> nil
              instance -> instance.config
            end

          instance ->
            instance.config
        end
      end

      def plugin_config({plugin_mod, as_alias}) when is_atom(plugin_mod) and is_atom(as_alias) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod and &1.as == as_alias)) do
          nil -> nil
          instance -> instance.config
        end
      end

      @doc "Returns the state slice for a specific plugin."
      @spec plugin_state(Jido.Agent.t(), module() | {module(), atom()}) :: map() | nil
      def plugin_state(agent, plugin_mod) when is_atom(plugin_mod) do
        case Enum.find(@plugin_instances, &(&1.module == plugin_mod and is_nil(&1.as))) do
          nil ->
            case Enum.find(@plugin_instances, &(&1.module == plugin_mod)) do
              nil -> nil
              instance -> Map.get(agent.state, instance.path)
            end

          instance ->
            Map.get(agent.state, instance.path)
        end
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

  defp quoted_new_function do
    quote do
      @doc "Creates a new agent with optional initial state."
      @spec new(keyword() | map()) :: Jido.Agent.t()
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

        %Jido.Agent{
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

      defp __build_initial_state__(opts) do
        user_state = __wrap_user_state__(opts[:state] || %{})

        own_path = path()
        own_user = Map.get(user_state, own_path, %{})
        own_slice = Jido.Agent.__seed_own_slice__(@validated_opts[:schema], own_user)

        plugin_slices = __seed_slice_states__(@plugin_instances, user_state)
        bare_slice_states = __seed_slice_states__(@slice_instances, user_state)

        known_slice_paths = [own_path | @plugin_paths ++ @slice_paths]
        leftover = Map.drop(user_state, known_slice_paths)

        leftover
        |> Map.merge(plugin_slices)
        |> Map.merge(bare_slice_states)
        |> Map.put(own_path, own_slice)
      end

      defp __seed_slice_states__(instances, user_state) do
        Enum.reduce(instances, %{}, fn instance, acc ->
          user_for_slice = Map.get(user_state, instance.path) || %{}
          merged_input = Map.merge(instance.config || %{}, user_for_slice)
          slice = Jido.Agent.__seed_plugin_slice__(instance.module, merged_input)
          Map.put(acc, instance.path, slice)
        end)
      end

      defp __wrap_user_state__(%{} = user_state) do
        known_slices = [path() | @plugin_paths ++ @slice_paths]

        cond do
          map_size(user_state) == 0 ->
            user_state

          Enum.any?(Map.keys(user_state), fn k -> k in known_slices end) ->
            user_state

          true ->
            %{path() => user_state}
        end
      end
    end
  end

  defp quoted_cmd_function do
    quote do
      @doc "Execute actions against the agent."
      @spec cmd(Jido.Agent.t(), Jido.Agent.action()) :: Jido.Agent.cmd_result()
      def cmd(%Jido.Agent{} = agent, action), do: cmd(agent, action, [])

      @spec cmd(Jido.Agent.t(), Jido.Agent.action(), keyword()) :: Jido.Agent.cmd_result()
      def cmd(%Jido.Agent{} = agent, action, opts) when is_list(opts) do
        {ctx, opts} = Keyword.pop(opts, :ctx, %{})
        {input_signal, instruction_opts} = Keyword.pop(opts, :input_signal)

        ctx = Map.put_new(ctx, :agent_id, agent.id)
        jido_instance = Map.get(ctx, :jido_instance) || Map.get(ctx, :jido)

        base_context =
          case input_signal do
            nil -> %{state: agent.state, ctx: ctx}
            signal -> %{state: agent.state, signal: signal, ctx: ctx}
          end

        case Jido.Instruction.normalize(action, base_context, instruction_opts) do
          {:ok, instructions} ->
            __run_cmd_loop__(agent, instructions, jido_instance)

          {:error, reason} ->
            {:error, Jido.Error.validation_error("Invalid action", %{reason: reason})}
        end
      end

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

      defp __run_instruction__(
             agent,
             %Jido.Instruction{action: action} = instruction,
             jido_instance
           ) do
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

        exec_opts = Jido.Observe.Config.action_exec_opts(jido_instance, instruction.opts)

        case Jido.Exec.run(%{instruction | opts: exec_opts}) do
          {:ok, new_slice, effects} when is_map(new_slice) ->
            {new_agent, dirs} =
              __apply_slice_result__(agent, slice_path, new_slice, List.wrap(effects))

            {:ok, new_agent, dirs}

          {:error, reason} ->
            {:error, Jido.Error.from_term(reason)}
        end
      end

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

      defp __apply_slice_result__(
             agent,
             _slice_path,
             %Jido.Agent.SliceUpdate{slices: slices},
             effects
           ) do
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

  defp quoted_utility_functions do
    quote do
      @doc "Updates the agent's state by merging new attributes."
      @spec set(Jido.Agent.t(), map() | keyword()) :: Jido.Agent.agent_result()
      def set(%Jido.Agent{} = agent, attrs) do
        wrapped = __wrap_user_state__(Map.new(attrs))
        new_state = Jido.Agent.State.merge(agent.state, wrapped)
        OK.success(%{agent | state: new_state})
      end

      @doc "Validates the agent's state against its schema."
      @spec validate(Jido.Agent.t(), keyword()) :: Jido.Agent.agent_result()
      def validate(%Jido.Agent{} = agent, opts \\ []) do
        case Jido.Agent.State.validate(agent.state, agent.schema, opts) do
          {:ok, validated_state} ->
            OK.success(%{agent | state: validated_state})

          {:error, reason} ->
            Jido.Error.validation_error("State validation failed", %{reason: reason})
            |> OK.failure()
        end
      end
    end
  end

  defp quoted_callbacks_and_overridables do
    quote do
      @impl true
      @spec signal_routes() :: list()
      def signal_routes, do: @expanded_signal_routes

      @impl true
      @spec signal_routes(map()) :: list()
      def signal_routes(_ctx), do: signal_routes()

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
                     slices: 0,
                     slice_instances: 0,
                     actions: 0,
                     capabilities: 0,
                     signal_types: 0,
                     plugin_config: 1,
                     plugin_state: 2,
                     plugin_routes: 0,
                     plugin_schedules: 0,
                     middleware: 0,
                     new: 1,
                     cmd: 2,
                     cmd: 3,
                     set: 2,
                     validate: 1,
                     validate: 2
    end
  end
end
