defmodule Jido.Memory.Agent do
  @moduledoc """
  Ergonomic helpers for reading and writing the `:memory` slice on an
  `%Jido.Agent{}` value, without going through the signal pipeline.

  The canonical entry point for production code is the slice's signal
  routes — `Jido.Memory.Slice` exposes `jido.memory.*` actions that are
  invokable via `MyAgent.cmd(agent, {Action, params})`. These helpers are
  thin adapters over `Jido.Memory`'s pure functions for tests and
  REPL-style construction where building a full module-based agent is
  overkill.

  ## Example

      alias Jido.Memory.Agent, as: MemoryAgent

      agent = MemoryAgent.ensure(agent)
      agent = MemoryAgent.put_in_space(agent, :world, :temperature, 22)
      temp  = MemoryAgent.get_in_space(agent, :world, :temperature)
  """

  alias Jido.Agent
  alias Jido.Memory
  alias Jido.Memory.Space

  @key :memory

  @doc "Returns the reserved key for memory storage."
  @spec key() :: atom()
  def key, do: @key

  @doc "Get memory from agent state."
  @spec get(Agent.t(), Memory.t() | nil) :: Memory.t() | nil
  def get(%Agent{state: state}, default \\ nil) do
    Map.get(state, @key, default)
  end

  @doc "Put memory into agent state."
  @spec put(Agent.t(), Memory.t()) :: Agent.t()
  def put(%Agent{} = agent, %Memory{} = memory) do
    %{agent | state: Map.put(agent.state, @key, memory)}
  end

  @doc "Update memory using a function."
  @spec update(Agent.t(), (Memory.t() | nil -> Memory.t())) :: Agent.t()
  def update(%Agent{} = agent, fun) when is_function(fun, 1) do
    put(agent, fun.(get(agent)))
  end

  @doc "Ensure agent has memory (initialize if missing)."
  @spec ensure(Agent.t(), keyword()) :: Agent.t()
  def ensure(%Agent{} = agent, opts \\ []) do
    case get(agent) do
      nil -> put(agent, Memory.new(opts))
      _memory -> agent
    end
  end

  @doc "Check if agent has memory."
  @spec has_memory?(Agent.t()) :: boolean()
  def has_memory?(%Agent{} = agent), do: get(agent) != nil

  @doc "Get a space by name."
  @spec space(Agent.t(), atom()) :: Space.t() | nil
  def space(%Agent{} = agent, name) when is_atom(name) do
    Memory.space(get(agent), name)
  end

  @doc "Put a space by name. Bumps container rev and updated_at."
  @spec put_space(Agent.t(), atom(), Space.t(), keyword()) :: Agent.t()
  def put_space(%Agent{} = agent, name, %Space{} = space, opts \\ []) when is_atom(name) do
    agent = ensure(agent)
    put(agent, Memory.put_space(get(agent), name, space, opts))
  end

  @doc "Update a space using a function. Bumps both space and container revisions."
  @spec update_space(Agent.t(), atom(), (Space.t() -> Space.t()), keyword()) :: Agent.t()
  def update_space(%Agent{} = agent, name, fun, opts \\ [])
      when is_atom(name) and is_function(fun, 1) do
    agent = ensure(agent)
    put(agent, Memory.update_space(get(agent), name, fun, opts))
  end

  @doc "Ensure a space exists with default data. Does not overwrite existing."
  @spec ensure_space(Agent.t(), atom(), map() | list()) :: Agent.t()
  def ensure_space(%Agent{} = agent, name, default_data) when is_atom(name) do
    agent = ensure(agent)
    put(agent, Memory.ensure_space(get(agent), name, default_data))
  end

  @doc "Delete a space. Raises on reserved spaces."
  @spec delete_space(Agent.t(), atom(), keyword()) :: Agent.t()
  def delete_space(%Agent{} = agent, name, opts \\ []) when is_atom(name) do
    agent = ensure(agent)
    put(agent, Memory.delete_space(get(agent), name, opts))
  end

  @doc "Get the full spaces map."
  @spec spaces(Agent.t()) :: map() | nil
  def spaces(%Agent{} = agent) do
    case get(agent) do
      nil -> nil
      %Memory{spaces: spaces} -> spaces
    end
  end

  @doc "Check if a space exists."
  @spec has_space?(Agent.t(), atom()) :: boolean()
  def has_space?(%Agent{} = agent, name) when is_atom(name) do
    Memory.has_space?(get(agent), name)
  end

  @doc "Get a key from a map space."
  @spec get_in_space(Agent.t(), atom(), term(), term()) :: term()
  def get_in_space(%Agent{} = agent, space_name, key, default \\ nil) do
    Memory.get_in_space(get(agent), space_name, key, default)
  end

  @doc "Put a key/value into a map space."
  @spec put_in_space(Agent.t(), atom(), term(), term()) :: Agent.t()
  def put_in_space(%Agent{} = agent, space_name, key, value) do
    agent = ensure(agent)
    put(agent, Memory.put_in_space(get(agent), space_name, key, value))
  end

  @doc "Delete a key from a map space."
  @spec delete_from_space(Agent.t(), atom(), term()) :: Agent.t()
  def delete_from_space(%Agent{} = agent, space_name, key) do
    agent = ensure(agent)
    put(agent, Memory.delete_from_space(get(agent), space_name, key))
  end

  @doc "Append an item to a list space."
  @spec append_to_space(Agent.t(), atom(), term()) :: Agent.t()
  def append_to_space(%Agent{} = agent, space_name, item) do
    agent = ensure(agent)
    put(agent, Memory.append_to_space(get(agent), space_name, item))
  end
end
