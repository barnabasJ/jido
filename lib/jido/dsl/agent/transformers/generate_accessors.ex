defmodule Jido.Dsl.Agent.Transformers.GenerateAccessors do
  @moduledoc """
  Final transformer in the agent DSL pipeline. Emits the agent's
  runtime API on the host module:

    * `new/1` — agent struct constructor
    * `cmd/2,3` — instruction dispatch loop
    * `set/2` / `validate/1,2` — state mutation helpers
    * `signal_routes/0,1` — `@behaviour Jido.Agent` callback impls
    * Internal `__build_initial_state__/1` and `__wrap_user_state__/1`
      that the constructor closes over per-agent path config.

  Agent introspection itself lives in `Jido.Dsl.Agent.Info`, which
  reads the same dsl_state this transformer's siblings persist.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(_), do: true

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    own_path = Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :path)
    own_schema = Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :schema, [])
    plugin_paths = Transformer.get_persisted(dsl_state, :plugin_paths, [])
    slice_paths = Transformer.get_persisted(dsl_state, :slice_paths, [])
    slice_paths_for_action = Transformer.get_persisted(dsl_state, :slice_paths_for_action, %{})
    mount_config_map = Transformer.get_persisted(dsl_state, :mount_config_map, %{})

    block =
      quote location: :keep do
        require OK

        unquote(quoted_new_function(own_path, own_schema, plugin_paths, slice_paths))
        unquote(quoted_cmd_function(slice_paths_for_action, mount_config_map))
        unquote(quoted_utility_functions())
        unquote(quoted_overridables())
      end

    {:ok, Transformer.eval(dsl_state, [], block)}
  end

  defp quoted_new_function(own_path, own_schema, plugin_paths, slice_paths) do
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
          name: Jido.Dsl.Agent.Info.name(__MODULE__),
          description: Jido.Dsl.Agent.Info.description(__MODULE__),
          category: Jido.Dsl.Agent.Info.category(__MODULE__),
          tags: Jido.Dsl.Agent.Info.tags(__MODULE__),
          vsn: Jido.Dsl.Agent.Info.vsn(__MODULE__),
          schema: Jido.Dsl.Agent.Info.schema(__MODULE__),
          state: initial_state
        }
      end

      unquote(quoted_build_initial_state(own_path, own_schema, plugin_paths, slice_paths))
      unquote(quoted_wrap_user_state(own_path, plugin_paths, slice_paths))

      defp __seed_slice_states__(instances, user_state) do
        Enum.reduce(instances, %{}, fn instance, acc ->
          user_for_slice = Map.get(user_state, instance.path) || %{}
          merged_input = Map.merge(instance.config || %{}, user_for_slice)

          slice =
            Jido.Agent.__seed_plugin_slice__(instance.module, merged_input, instance.path)

          Map.put(acc, instance.path, slice)
        end)
      end
    end
  end

  defp quoted_build_initial_state(nil, _own_schema, plugin_paths, slice_paths) do
    quote do
      defp __build_initial_state__(opts) do
        user_state = __wrap_user_state__(opts[:state] || %{})

        plugin_instances = Jido.Dsl.Agent.Info.plugin_instances(__MODULE__)
        slice_instances = Jido.Dsl.Agent.Info.slice_instances(__MODULE__)

        plugin_slices = __seed_slice_states__(plugin_instances, user_state)
        bare_slice_states = __seed_slice_states__(slice_instances, user_state)

        known_slice_paths = unquote(plugin_paths) ++ unquote(slice_paths)
        leftover = Map.drop(user_state, known_slice_paths)

        leftover
        |> Map.merge(plugin_slices)
        |> Map.merge(bare_slice_states)
      end
    end
  end

  defp quoted_build_initial_state(own_path, own_schema, plugin_paths, slice_paths)
       when is_atom(own_path) do
    own_schema_escaped = Macro.escape(own_schema)

    quote do
      defp __build_initial_state__(opts) do
        user_state = __wrap_user_state__(opts[:state] || %{})

        plugin_instances = Jido.Dsl.Agent.Info.plugin_instances(__MODULE__)
        slice_instances = Jido.Dsl.Agent.Info.slice_instances(__MODULE__)

        plugin_slices = __seed_slice_states__(plugin_instances, user_state)
        bare_slice_states = __seed_slice_states__(slice_instances, user_state)

        known_slice_paths =
          [unquote(own_path) | unquote(plugin_paths) ++ unquote(slice_paths)]

        leftover = Map.drop(user_state, known_slice_paths)

        own_user = Map.get(user_state, unquote(own_path), %{})
        own_slice = Jido.Agent.__seed_own_slice__(unquote(own_schema_escaped), own_user)

        leftover
        |> Map.merge(plugin_slices)
        |> Map.merge(bare_slice_states)
        |> Map.put(unquote(own_path), own_slice)
      end
    end
  end

  defp quoted_wrap_user_state(nil, _plugin_paths, _slice_paths) do
    quote do
      defp __wrap_user_state__(%{} = user_state), do: user_state
    end
  end

  defp quoted_wrap_user_state(own_path, plugin_paths, slice_paths) when is_atom(own_path) do
    quote do
      defp __wrap_user_state__(%{} = user_state) do
        known_slices = [unquote(own_path) | unquote(plugin_paths) ++ unquote(slice_paths)]

        cond do
          map_size(user_state) == 0 ->
            user_state

          Enum.any?(Map.keys(user_state), fn k -> k in known_slices end) ->
            user_state

          true ->
            %{unquote(own_path) => user_state}
        end
      end
    end
  end

  defp quoted_cmd_function(slice_paths_for_action, mount_config_map) do
    quote do
      @slice_paths_for_action unquote(Macro.escape(slice_paths_for_action))
      @mount_config_map unquote(Macro.escape(mount_config_map))
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

      # Fan out a single Instruction across every mount path that owns the
      # action. The fold is atomic per-instruction: any mount returning
      # `{:error, _}` halts and earlier mounts' state mutations within this
      # fan-out drop on the floor (the outer __run_cmd_loop__ keeps its
      # input agent on halt — same all-or-nothing guarantee as the
      # single-mount case, applied uniformly across N mounts).
      defp __run_instruction__(
             agent,
             %Jido.Instruction{action: action} = instruction,
             jido_instance
           ) do
        paths = __resolve_slice_paths__(action)

        Enum.reduce_while(paths, {:ok, agent, []}, fn mount_path, {:ok, acc_agent, acc_dirs} ->
          scoped_state = Map.get(acc_agent.state, mount_path, %{})
          slice_config = Map.get(@mount_config_map, mount_path, %{})

          per_mount = %{
            instruction
            | context:
                instruction.context
                |> Map.put(:state, scoped_state)
                |> Map.put(:agent, acc_agent)
                |> Map.put(:agent_server_pid, self())
                |> Map.put(:slice_path, mount_path)
                |> Map.put(:slice_config, slice_config)
          }

          exec_opts = Jido.Observe.Config.action_exec_opts(jido_instance, per_mount.opts)

          case Jido.Exec.run(%{per_mount | opts: exec_opts}) do
            {:ok, new_slice, effects} when is_map(new_slice) ->
              {new_agent, dirs} =
                __apply_slice_result__(acc_agent, mount_path, new_slice, List.wrap(effects))

              {:cont, {:ok, new_agent, acc_dirs ++ dirs}}

            {:error, reason} ->
              {:halt, {:error, Jido.Error.from_term(reason)}}
          end
        end)
      end

      defp __resolve_slice_paths__(action)
           when is_atom(action) and not is_nil(action) do
        # Resolution order:
        #   1. Every mount that owns the action via its `signal_routes`,
        #      plus the agent's own path if the action is also declared on
        #      the agent's own `signal_routes` (compile-time list-valued
        #      lookup table).
        #   2. Fall back to a single-element list with the action's own
        #      `path :foo` escape valve, then the agent's own path.
        case Map.get(@slice_paths_for_action, action) do
          [_ | _] = paths ->
            paths

          _ ->
            [__fallback_slice_path__(action)]
        end
      rescue
        UndefinedFunctionError -> [Jido.Dsl.Agent.Info.path(__MODULE__)]
      end

      defp __resolve_slice_paths__(_action), do: [Jido.Dsl.Agent.Info.path(__MODULE__)]

      defp __fallback_slice_path__(action) do
        case Jido.Dsl.Action.Info.path(action) do
          path when is_atom(path) and not is_nil(path) -> path
          _ -> Jido.Dsl.Agent.Info.path(__MODULE__)
        end
      rescue
        UndefinedFunctionError -> Jido.Dsl.Agent.Info.path(__MODULE__)
      end

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

  defp quoted_overridables do
    quote do
      defoverridable new: 1,
                     cmd: 2,
                     cmd: 3,
                     set: 2,
                     validate: 1,
                     validate: 2
    end
  end
end
