defmodule Jido.Storage.ETS.TableOwner do
  @moduledoc false
  # Long-running owner for ETS storage tables. Holds the named tables alive
  # for the entire BEAM session so that hibernate IO from a terminating agent
  # process doesn't lose the data when that process dies.
  #
  # Tables are created on demand via `ensure/3` (a process-safe call into the
  # owner). The owner uses `:public` access so any process can read/write.

  use GenServer

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Ensures the named table exists, owned by the long-running owner process.
  Idempotent. Returns `:ok` once the table exists.
  """
  @spec ensure(atom(), [atom()]) :: :ok
  def ensure(name, extra_opts) when is_atom(name) and is_list(extra_opts) do
    case :ets.whereis(name) do
      :undefined ->
        case Process.whereis(@name) do
          nil ->
            # Owner not running yet (e.g. during early app startup) — fall
            # back to creating the table here. It will be inherited by the
            # caller's process. Tests that exercise this path should ensure
            # the application is started.
            :ets.new(name, [:named_table, :public, read_concurrency: true] ++ extra_opts)
            :ok

          _pid ->
            GenServer.call(@name, {:ensure, name, extra_opts})
        end

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    {:ok, %{tables: MapSet.new()}}
  end

  @impl true
  def handle_call({:ensure, name, extra_opts}, _from, state) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:named_table, :public, read_concurrency: true] ++ extra_opts)
        {:reply, :ok, %{state | tables: MapSet.put(state.tables, name)}}

      _ref ->
        {:reply, :ok, state}
    end
  rescue
    ArgumentError -> {:reply, :ok, state}
  end
end
