defmodule Jido.AgentServer.SignalRouter do
  @moduledoc """
  Builds a unified Jido.Signal.Router from agent and slice routes.

  This module is responsible for:
  1. Collecting routes from all sources (agent, slices)
  2. Normalizing route specs with appropriate priorities
  3. Building the trie-based router for efficient signal routing

  ## Priority Levels

  | Source | Default Priority | Range     |
  |--------|------------------|-----------|
  | Agent  | 0                | -25 to 25 |
  | Slice  | -10              | -50 to -10|

  ## Route Spec Formats

  Routes can be specified in several formats:
  - `{path, target}` - Simple route with default priority
  - `{path, target, priority}` - Route with explicit priority
  - `{path, match_fn, target}` - Route with match function
  - `{path, match_fn, target, priority}` - Route with match function and priority

  ## Target Types

  - `module()` - Action module, params = signal.data
  - `{module(), map()}` - Action module with static params
  """

  alias Jido.AgentServer.State
  alias Jido.Signal.Router, as: SignalRouter

  @agent_default_priority 0
  @slice_default_priority -10

  @doc """
  Builds a unified router from all route sources in the agent state.

  Collects routes from:
  - Agent routes (priority 0) via `agent_module.signal_routes/1`
  - Slice routes (priority -10) via slice `signal_routes/0`

  Returns an empty router if no routes are found or if building fails.
  """
  @spec build(State.t()) :: SignalRouter.Router.t()
  def build(%State{} = state) do
    routes =
      []
      |> add_agent_routes(state)
      |> add_slice_routes(state)
      |> add_builtin_routes()

    case SignalRouter.new(routes) do
      {:ok, router} -> router
      {:error, _} -> SignalRouter.new!([])
    end
  end

  # Built-in system routes available on every agent. Priority sits below
  # slice/agent so user-defined routes always win on conflict.
  defp add_builtin_routes(routes) do
    builtin = [
      {"jido.agent.query.children", Jido.AgentServer.Actions.QueryChildren}
    ]

    routes ++ normalize_routes(builtin, @slice_default_priority - 10)
  end

  # Collects routes for the agent. Users may override `signal_routes/1`
  # on their `use Jido.Agent` module to compute routes from a runtime
  # `ctx`; otherwise the default is the `signal_routes do …` section
  # the agent declared.
  defp add_agent_routes(routes, %State{
         agent_module: agent_module,
         jido: jido_instance,
         partition: partition
       }) do
    ctx = %{agent_module: agent_module, jido_instance: jido_instance, partition: partition}

    agent_routes =
      if function_exported?(agent_module, :signal_routes, 1) do
        agent_module.signal_routes(ctx)
      else
        Jido.Dsl.Agent.Info.signal_routes(agent_module)
      end

    normalized = normalize_routes(agent_routes, @agent_default_priority)
    routes ++ normalized
  end

  # Collects routes from slices via the agent's pre-expanded `routes/1`
  # table — the slice DSL's `signal_routes do … end` block is the
  # single source of truth for slice routes. Already normalized with
  # priority by the agent transformer pipeline.
  defp add_slice_routes(routes, %State{agent_module: agent_module}) do
    routes ++ Jido.Dsl.Agent.Info.routes(agent_module)
  end

  defp normalize_routes(routes, default_priority) do
    Enum.map(routes, fn
      {path, target, priority} when is_integer(priority) ->
        {path, target, priority}

      {path, match_fn, target, priority} when is_function(match_fn, 1) and is_integer(priority) ->
        {path, match_fn, target, priority}

      {path, match_fn, target} when is_function(match_fn, 1) ->
        {path, match_fn, target, default_priority}

      {path, target} ->
        {path, target, default_priority}
    end)
  end
end
