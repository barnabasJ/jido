defmodule Jido.Dsl.Instance.Transformers.GenerateAccessors do
  @moduledoc """
  Reads the `instance do … end` section and emits the runtime instance
  surface: `__otp_app__/0`, `__jido_storage__/0`, `__default_slices__/0`,
  `child_spec/1`, `start_link/1`, `config/1`, agent-lifecycle delegators
  (`start_agent/2`, `stop_agent/2`, `whereis/2`, `list_agents/1`,
  `agent_count/1`), runtime names (`registry_name/0`, …), persistence
  helpers (`hibernate/2`, `thaw/3`), and debug helpers.

  `__jido_storage__/0` and `__default_slices__/0` defer to
  `Jido.Dsl.Instance.Info` at runtime rather than baking the value via
  `Macro.escape/1`, so any storage tuples that carry `&Mod.fun/arity`
  references work cleanly. Anonymous `fn x -> … end` closures with
  captured locals are not supported in `storage:` — pass `&Mod.fun/arity`
  capture syntax instead.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    otp_app = Spark.Dsl.Extension.get_opt(dsl_state, [:instance], :otp_app)

    block =
      quote location: :keep do
        unquote(quoted_otp_app(otp_app))
        unquote(quoted_storage())
        unquote(quoted_default_slices())
        unquote(quoted_child_spec_start_link_config())
        unquote(quoted_agent_lifecycle())
        unquote(quoted_runtime_names())
        unquote(quoted_persistence())
        unquote(quoted_debug())
      end

    {:ok, Transformer.eval(dsl_state, [], block)}
  end

  defp quoted_otp_app(otp_app) do
    quote do
      @otp_app unquote(otp_app)

      @doc false
      @spec __otp_app__() :: atom()
      def __otp_app__, do: @otp_app
    end
  end

  defp quoted_storage do
    quote do
      @doc "Returns the storage configuration for this Jido instance."
      @spec __jido_storage__() :: {module(), keyword()}
      def __jido_storage__,
        do: Jido.Storage.normalize_storage(Jido.Dsl.Instance.Info.storage(__MODULE__))
    end
  end

  defp quoted_default_slices do
    quote do
      @dialyzer {:nowarn_function, [__default_slices__: 0]}
      @doc "Returns the default slices for agents bound to this Jido instance."
      @spec __default_slices__() :: [Jido.Agent.DefaultSlices.default_entry()]
      def __default_slices__ do
        base =
          Application.get_env(@otp_app, __MODULE__, [])
          |> Keyword.get(:default_slices) ||
            Jido.Agent.DefaultSlices.package_defaults()

        override = Jido.Dsl.Instance.Info.default_slices(__MODULE__)
        Jido.Agent.DefaultSlices.apply_agent_overrides(base, override)
      end
    end
  end

  defp quoted_child_spec_start_link_config do
    quote do
      @doc false
      def child_spec(init_arg \\ []) do
        opts =
          config(init_arg)
          |> Keyword.put_new(:name, __MODULE__)
          |> Keyword.put_new(:otp_app, @otp_app)

        Jido.child_spec(opts)
      end

      @doc false
      def start_link(init_arg \\ []) do
        opts =
          config(init_arg)
          |> Keyword.put_new(:name, __MODULE__)
          |> Keyword.put_new(:otp_app, @otp_app)

        Jido.start_link(opts)
      end

      @doc "Returns the runtime config for this Jido instance."
      @spec config(keyword()) :: keyword()
      def config(overrides \\ []) do
        @otp_app
        |> Application.get_env(__MODULE__, [])
        |> Keyword.merge(overrides)
      end

      defoverridable config: 1
    end
  end

  defp quoted_agent_lifecycle do
    quote do
      @doc "Starts an agent under this Jido instance."
      @spec start_agent(module() | struct(), keyword()) :: DynamicSupervisor.on_start_child()
      def start_agent(agent, opts \\ []) do
        Jido.start_agent(__MODULE__, agent, opts)
      end

      @doc "Stops an agent (by pid or id) under this Jido instance."
      @spec stop_agent(pid() | String.t(), keyword()) :: :ok | {:error, :not_found}
      def stop_agent(pid_or_id, opts \\ []) when is_list(opts) do
        Jido.stop_agent(__MODULE__, pid_or_id, opts)
      end

      @doc "Looks up an agent by ID under this Jido instance."
      @spec whereis(String.t(), keyword()) :: pid() | nil
      def whereis(id, opts \\ []) when is_binary(id) and is_list(opts) do
        Jido.whereis(__MODULE__, id, opts)
      end

      @doc "Lists all agents under this Jido instance."
      @spec list_agents(keyword()) :: [{String.t(), pid()}]
      def list_agents(opts \\ []) when is_list(opts) do
        Jido.list_agents(__MODULE__, opts)
      end

      @doc "Returns the count of running agents under this Jido instance."
      @spec agent_count(keyword()) :: non_neg_integer()
      def agent_count(opts \\ []) when is_list(opts) do
        Jido.agent_count(__MODULE__, opts)
      end
    end
  end

  defp quoted_runtime_names do
    quote do
      @doc "Returns the Registry name for this Jido instance."
      @spec registry_name() :: atom()
      def registry_name, do: Jido.registry_name(__MODULE__)

      @doc "Returns the AgentSupervisor name for this Jido instance."
      @spec agent_supervisor_name() :: atom()
      def agent_supervisor_name, do: Jido.agent_supervisor_name(__MODULE__)

      @doc "Returns the TaskSupervisor name for this Jido instance."
      @spec task_supervisor_name() :: atom()
      def task_supervisor_name, do: Jido.task_supervisor_name(__MODULE__)

      @doc "Returns the RuntimeStore name for this Jido instance."
      @spec runtime_store_name() :: atom()
      def runtime_store_name, do: Jido.runtime_store_name(__MODULE__)
    end
  end

  defp quoted_persistence do
    quote do
      @doc "Hibernate an agent to storage."
      @spec hibernate(Jido.Agent.t(), keyword()) :: :ok | {:error, term()}
      def hibernate(agent, opts \\ []) when is_list(opts) do
        Jido.hibernate(__MODULE__, agent, opts)
      end

      @doc "Thaw an agent from storage."
      @spec thaw(module(), term(), keyword()) :: {:ok, Jido.Agent.t()} | {:error, term()}
      def thaw(agent_module, key, opts \\ []) when is_list(opts) do
        Jido.thaw(__MODULE__, agent_module, key, opts)
      end
    end
  end

  defp quoted_debug do
    quote do
      @doc "Controls debug mode for this Jido instance."
      @spec debug() :: Jido.Debug.level()
      def debug, do: Jido.Debug.level(__MODULE__)

      @spec debug(Jido.Debug.level() | pid()) :: :ok | {:error, term()} | Jido.Debug.level()
      def debug(pid) when is_pid(pid), do: Jido.AgentServer.set_debug(pid, true)
      def debug(level) when is_atom(level), do: Jido.Debug.enable(__MODULE__, level)

      @spec debug(Jido.Debug.level(), keyword()) :: :ok
      def debug(level, opts) when is_atom(level),
        do: Jido.Debug.enable(__MODULE__, level, opts)

      @doc "Returns recent debug events from an agent's ring buffer."
      @spec recent(pid(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
      def recent(pid, limit \\ 50), do: Jido.AgentServer.recent_events(pid, limit: limit)

      @doc "Returns the current debug status for this instance."
      @spec debug_status() :: map()
      def debug_status, do: Jido.Debug.status(__MODULE__)
    end
  end
end
