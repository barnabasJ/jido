defmodule Jido do
  use Supervisor

  alias Jido.Agent.WorkerPool
  alias Jido.Config.Defaults
  alias Jido.RuntimeStore

  @moduledoc """
  自動 (Jido) - An autonomous agent framework for Elixir, built for workflows and
  multi-agent systems.

  ## Quick Start

  Create a Jido supervisor in your application:

      defmodule MyApp.Jido do
        use Jido, otp_app: :my_app
      end

  Add to your supervision tree:

      children = [MyApp.Jido]

  Start and manage agents:

      {:ok, pid} = MyApp.Jido.start_agent(MyAgent, id: "agent-1")
      pid = MyApp.Jido.whereis("agent-1")
      agents = MyApp.Jido.list_agents()
      :ok = MyApp.Jido.stop_agent("agent-1")

  ## Core Concepts

  Jido agents are immutable data structures. The core operation is `cmd/2`:

      {agent, directives} = MyAgent.cmd(agent, MyAction)

  - **Agents** — Immutable structs updated via commands
  - **Actions** — Functions that transform agent state (may perform side effects)
  - **Directives** — Descriptions of external effects (signals, processes, etc.)

  ## For Tests

  Use `JidoTest.Case` for isolation:

      defmodule MyAgentTest do
        use JidoTest.Case, async: true

        test "agent works", %{jido: jido} do
          {:ok, pid} = Jido.start_agent(jido, MyAgent)
          # ...
        end
      end

  See `Jido.Agent` for defining agents and `Jido.AgentServer` for the
  signal-driven runtime (including the `call/4` and `subscribe/4`
  primitives for coordination).
  """

  @doc """
  Creates a Jido supervisor module.

  ## Options

    - `:otp_app` - Required. Your application name (e.g., `:my_app`).

  ## Example

      defmodule MyApp.Jido do
        use Jido, otp_app: :my_app
      end

  Then add to your supervision tree in `lib/my_app/application.ex`:

      children = [MyApp.Jido]

  Optionally configure in `config/config.exs` to customize defaults:

      config :my_app, MyApp.Jido,
        max_tasks: 2000,
        agent_pools: []
  """
  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    storage = Keyword.get(opts, :storage)
    default_slices = Keyword.get(opts, :default_slices)

    instance_options =
      [{:otp_app, otp_app}, {:storage, storage}, {:default_slices, default_slices}]
      |> Enum.filter(fn {key, val} -> key == :otp_app or val != nil end)
      |> Enum.map(fn {key, val} ->
        quote do: unquote(key)(unquote(val))
      end)

    instance_block = {:__block__, [], instance_options}

    quote location: :keep do
      use Jido.Dsl.Instance.Host

      instance do
        unquote(instance_block)
      end
    end
  end

  @type agent_id :: String.t() | atom()
  @type partition :: term()

  # Default instance name for scripts/Livebook
  @default_instance Jido.Default

  @doc """
  Returns the default Jido instance name.

  Used by `Jido.start/1` for scripts and Livebook quick-start.
  """
  @spec default_instance() :: atom()
  def default_instance, do: @default_instance

  # ---------------------------------------------------------------------------
  # Debug API (default instance delegates)
  # ---------------------------------------------------------------------------

  @doc """
  Controls debug mode for the default Jido instance (`Jido.Default`).

  - `debug()` — returns current debug level
  - `debug(:on)` — enable developer-friendly verbosity
  - `debug(:verbose)` — enable maximum detail
  - `debug(:off)` — disable debug overrides
  """
  @spec debug() :: Jido.Debug.level()
  def debug, do: Jido.Debug.level(@default_instance)

  @spec debug(Jido.Debug.level()) :: :ok
  def debug(level) when is_atom(level), do: Jido.Debug.enable(@default_instance, level)

  @spec debug(Jido.Debug.level(), keyword()) :: :ok
  def debug(level, opts) when is_atom(level),
    do: Jido.Debug.enable(@default_instance, level, opts)

  @doc """
  Start the default Jido instance for scripts and Livebook.

  This is an idempotent convenience function - safe to call multiple times
  (returns `{:ok, pid}` even if already started).

  ## Examples

      # In a script or Livebook
      {:ok, _} = Jido.start()
      {:ok, pid} = Jido.start_agent(Jido.default_instance(), MyAgent)

      # With custom options
      {:ok, _} = Jido.start(max_tasks: 2000)

  ## Options

  Same as `start_link/1`, but `:name` defaults to `Jido.Default`.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    opts = Keyword.put_new(opts, :name, @default_instance)

    case start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Stop a Jido instance.

  Defaults to stopping the default instance (`Jido.Default`).

  ## Examples

      Jido.stop()
      Jido.stop(MyApp.Jido)

  """
  @spec stop(atom()) :: :ok
  def stop(name \\ @default_instance) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  @doc """
  Starts a Jido instance supervisor.

  ## Options
    - `:name` - Required. The name of this Jido instance (e.g., `MyApp.Jido`)

  ## Example

      {:ok, pid} = Jido.start_link(name: MyApp.Jido)
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: Defaults.jido_shutdown_timeout_ms()
    }
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    runtime_store = runtime_store_name(name)

    if otp_app = opts[:otp_app] do
      Jido.Debug.maybe_enable_from_config(otp_app, name)
    end

    :ok = Jido.RuntimeStore.ensure_table(runtime_store)

    base_children = [
      {Task.Supervisor,
       name: task_supervisor_name(name), max_children: Keyword.get(opts, :max_tasks, 1000)},
      {Registry, keys: :unique, name: registry_name(name)},
      {Jido.RuntimeStore, name: runtime_store},
      {DynamicSupervisor,
       name: agent_supervisor_name(name),
       strategy: :one_for_one,
       max_restarts: 1000,
       max_seconds: 5}
    ]

    pool_children =
      WorkerPool.build_pool_child_specs(name, Keyword.get(opts, :agent_pools, []))

    Supervisor.init(base_children ++ pool_children, strategy: :one_for_one)
  end

  @doc """
  Generate a unique identifier.

  Delegates to `Jido.Util.generate_id/0`.
  """
  defdelegate generate_id(), to: Jido.Util

  @doc "Returns the Registry name for a Jido instance."
  @spec registry_name(atom()) :: atom()
  def registry_name(name), do: Module.concat(name, Registry)

  @doc "Returns the AgentSupervisor name for a Jido instance."
  @spec agent_supervisor_name(atom()) :: atom()
  def agent_supervisor_name(name), do: Module.concat(name, AgentSupervisor)

  @doc "Returns the TaskSupervisor name for a Jido instance."
  @spec task_supervisor_name(atom()) :: atom()
  def task_supervisor_name(name), do: Module.concat(name, TaskSupervisor)

  @doc "Returns the RuntimeStore name for a Jido instance."
  @spec runtime_store_name(atom()) :: atom()
  def runtime_store_name(name), do: Module.concat(name, RuntimeStore)

  @doc "Returns the Scheduler name for a Jido instance."
  @spec scheduler_name(atom()) :: atom()
  def scheduler_name(name), do: Module.concat(name, Scheduler)

  @doc "Returns the AgentPool name for a specific pool in a Jido instance."
  @spec agent_pool_name(atom(), atom()) :: atom()
  def agent_pool_name(name, pool_name), do: Module.concat([name, AgentPool, pool_name])

  @doc false
  @spec partition_key(term(), partition() | nil) :: term()
  def partition_key(value, nil), do: value
  def partition_key(value, partition), do: {:partition, partition, value}

  @doc false
  @spec unwrap_partition_key(term()) :: {partition() | nil, term()}
  def unwrap_partition_key({:partition, partition, value}), do: {partition, value}
  def unwrap_partition_key(value), do: {nil, value}

  # ---------------------------------------------------------------------------
  # Agent Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts an agent under a specific Jido instance.

  ## Examples

      {:ok, pid} = Jido.start_agent(MyApp.Jido, MyAgent)
      {:ok, pid} = Jido.start_agent(MyApp.Jido, MyAgent, id: "custom-id")
  """
  @spec start_agent(atom(), module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(jido_instance, agent_module, opts \\ [])
      when is_atom(jido_instance) and is_atom(agent_module) do
    child_spec =
      {Jido.AgentServer, Keyword.merge(opts, agent_module: agent_module, jido: jido_instance)}

    DynamicSupervisor.start_child(agent_supervisor_name(jido_instance), child_spec)
  end

  @doc """
  Stops an agent by pid or id.

  ## Examples

      :ok = Jido.stop_agent(MyApp.Jido, pid)
      :ok = Jido.stop_agent(MyApp.Jido, "agent-id")
  """
  @spec stop_agent(atom(), pid() | String.t()) :: :ok | {:error, :not_found}
  def stop_agent(jido_instance, pid) when is_atom(jido_instance) and is_pid(pid) do
    DynamicSupervisor.terminate_child(agent_supervisor_name(jido_instance), pid)
  end

  def stop_agent(jido_instance, id) when is_atom(jido_instance) and is_binary(id) do
    case whereis(jido_instance, id) do
      nil -> {:error, :not_found}
      pid -> stop_agent(jido_instance, pid)
    end
  end

  @spec stop_agent(atom(), pid() | String.t(), keyword()) :: :ok | {:error, :not_found}
  def stop_agent(jido_instance, pid, _opts)
      when is_atom(jido_instance) and is_pid(pid) do
    stop_agent(jido_instance, pid)
  end

  def stop_agent(jido_instance, id, opts)
      when is_atom(jido_instance) and is_binary(id) and is_list(opts) do
    case whereis(jido_instance, id, opts) do
      nil -> {:error, :not_found}
      pid -> stop_agent(jido_instance, pid)
    end
  end

  @doc """
  Looks up an agent by ID in a Jido instance's registry.

  Returns the pid if found, nil otherwise.

  ## Examples

      pid = Jido.whereis(MyApp.Jido, "agent-123")
  """
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(jido_instance, id) when is_atom(jido_instance) and is_binary(id) do
    whereis(jido_instance, id, [])
  end

  @spec whereis(atom(), String.t(), keyword()) :: pid() | nil
  def whereis(jido_instance, id, opts)
      when is_atom(jido_instance) and is_binary(id) and is_list(opts) do
    registry_key = partition_key(id, Keyword.get(opts, :partition))

    case Registry.lookup(registry_name(jido_instance), registry_key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Fetches the persisted logical parent binding for a child agent.

  This is the stable runtime relationship lookup API for orchestration layers
  that need to inspect the live parent/child graph without depending on raw
  `RuntimeStore` hive layout.

  Returns `{:ok, binding}` when present, or `:error` when no binding exists.

  ## Examples

      {:ok, binding} = Jido.parent_binding(MyApp.Jido, "child-123")
      assert binding.parent_id == "parent-456"
  """
  @spec parent_binding(atom(), String.t()) :: {:ok, map()} | :error
  def parent_binding(jido_instance, child_id)
      when is_atom(jido_instance) and is_binary(child_id) do
    parent_binding(jido_instance, child_id, [])
  end

  @spec parent_binding(atom(), String.t(), keyword()) :: {:ok, map()} | :error
  def parent_binding(jido_instance, child_id, opts)
      when is_atom(jido_instance) and is_binary(child_id) and is_list(opts) do
    case RuntimeStore.fetch(
           jido_instance,
           :relationships,
           partition_key(child_id, Keyword.get(opts, :partition))
         ) do
      {:ok, binding} -> normalize_parent_binding(binding)
      :error -> :error
    end
  end

  @doc """
  Lists all agents running in a Jido instance.

  Returns a list of `{id, pid}` tuples.

  ## Examples

      agents = Jido.list_agents(MyApp.Jido)
      # => [{"agent-1", #PID<0.123.0>}, {"agent-2", #PID<0.124.0>}]
  """
  @spec list_agents(atom()) :: [{String.t(), pid()}]
  def list_agents(jido_instance) when is_atom(jido_instance) do
    list_agents(jido_instance, [])
  end

  @spec list_agents(atom(), keyword()) :: [{String.t(), pid()}]
  def list_agents(jido_instance, opts) when is_atom(jido_instance) and is_list(opts) do
    registry_name(jido_instance)
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> filter_agent_registry_entries(Keyword.get(opts, :partition))
  end

  @doc """
  Returns the count of running agents in a Jido instance.

  ## Examples

      count = Jido.agent_count(MyApp.Jido)
      # => 5
  """
  @spec agent_count(atom()) :: non_neg_integer()
  def agent_count(jido_instance) when is_atom(jido_instance) do
    agent_count(jido_instance, [])
  end

  @spec agent_count(atom(), keyword()) :: non_neg_integer()
  def agent_count(jido_instance, opts) when is_atom(jido_instance) and is_list(opts) do
    jido_instance
    |> list_agents(opts)
    |> length()
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  @doc "Hibernate an agent using the given Jido instance."
  @spec hibernate(atom(), Jido.Agent.t()) :: :ok | {:error, term()}
  def hibernate(jido_instance, agent) when is_atom(jido_instance) do
    hibernate(jido_instance, agent, [])
  end

  @spec hibernate(atom(), Jido.Agent.t(), keyword()) :: :ok | {:error, term()}
  def hibernate(jido_instance, agent, opts) when is_atom(jido_instance) and is_list(opts) do
    partition = Keyword.get(opts, :partition)
    agent_module = agent_module_for(agent)
    Jido.Persist.hibernate(jido_instance, agent_module, partition_key(agent.id, partition), agent)
  end

  @doc "Thaw an agent using the given Jido instance."
  @spec thaw(atom(), module(), term()) :: {:ok, Jido.Agent.t()} | {:error, term()}
  def thaw(jido_instance, agent_module, key) when is_atom(jido_instance) do
    thaw(jido_instance, agent_module, key, [])
  end

  @spec thaw(atom(), module(), term(), keyword()) :: {:ok, Jido.Agent.t()} | {:error, term()}
  def thaw(jido_instance, agent_module, key, opts)
      when is_atom(jido_instance) and is_list(opts) do
    partition = Keyword.get(opts, :partition)
    Jido.Persist.thaw(jido_instance, agent_module, partition_key(key, partition))
  end

  defp filter_agent_registry_entries(entries, partition) do
    Enum.flat_map(entries, fn {registry_key, pid} ->
      case unwrap_partition_key(registry_key) do
        {^partition, id} when is_binary(id) ->
          [{id, pid}]

        {nil, id} when is_nil(partition) and is_binary(id) ->
          [{id, pid}]

        _other ->
          []
      end
    end)
  end

  defp agent_module_for(%{agent_module: mod}) when is_atom(mod) and not is_nil(mod), do: mod
  defp agent_module_for(%mod{}), do: mod

  defp normalize_parent_binding(%{parent_id: parent_id, tag: _tag} = binding)
       when is_binary(parent_id) do
    {:ok,
     binding
     |> Map.put_new(:parent_partition, nil)
     |> Map.update(:meta, %{}, fn
       meta when is_map(meta) -> meta
       _other -> %{}
     end)}
  end

  defp normalize_parent_binding(_binding), do: :error

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  @doc "Lists discovered Actions with optional filtering."
  defdelegate list_actions(opts \\ []), to: Jido.Discovery

  @doc "Lists discovered Sensors with optional filtering."
  defdelegate list_sensors(opts \\ []), to: Jido.Discovery

  @doc "Lists discovered Slices with optional filtering."
  defdelegate list_slices(opts \\ []), to: Jido.Discovery

  @doc "Lists discovered Demos with optional filtering."
  defdelegate list_demos(opts \\ []), to: Jido.Discovery

  @doc "Gets an Action by its slug."
  defdelegate get_action_by_slug(slug), to: Jido.Discovery

  @doc "Gets a Sensor by its slug."
  defdelegate get_sensor_by_slug(slug), to: Jido.Discovery

  @doc "Gets a Slice by its slug."
  defdelegate get_slice_by_slug(slug), to: Jido.Discovery

  @doc "Refreshes the Discovery catalog."
  defdelegate refresh_discovery(), to: Jido.Discovery, as: :refresh
end
