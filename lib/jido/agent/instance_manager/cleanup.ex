defmodule Jido.Agent.InstanceManager.Cleanup do
  @moduledoc false
  use GenServer

  @type manager_name :: atom()
  @type manager_config :: map()

  @doc false
  @spec start_link(args :: manager_name() | {manager_name(), manager_config()}) ::
          GenServer.on_start()
  def start_link(name) do
    GenServer.start_link(__MODULE__, name)
  end

  @impl GenServer
  @spec init(args :: manager_name() | {manager_name(), manager_config()}) :: {:ok, manager_name()}
  def init({name, config}) do
    :persistent_term.put({Jido.Agent.InstanceManager, name}, config)
    init(name)
  end

  def init(name) do
    Process.flag(:trap_exit, true)
    {:ok, name}
  end

  @impl GenServer
  @spec terminate(reason :: term(), name :: manager_name()) :: :ok
  def terminate(_reason, name) do
    :persistent_term.erase({Jido.Agent.InstanceManager, name})
    :ok
  end
end
