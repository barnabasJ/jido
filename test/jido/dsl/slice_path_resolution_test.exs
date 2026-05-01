defmodule Jido.Dsl.SlicePathResolutionTest do
  @moduledoc """
  Targeted coverage for the `__resolve_slice_paths__/1` resolution
  order:

    1. Every mount that routes to the action via its `signal_routes`
       (the compile-time `:slice_paths_for_action` lookup table). Returns
       a list — multi-instance mounts contribute multiple entries; the
       agent's own path is appended when the agent's own `signal_routes`
       also declares the action.
    2. Fallback (when the table has no entry for the action): the
       action's own `path :foo` escape valve (for ad-hoc actions on the
       agent's own `signal_routes` that aren't owned by any slice).
    3. Final fallback: the agent's own `path :foo` (its `agent do … end`
       slice).

  Steps 2 and 3 yield a single-element list so the runtime fan-out fold
  in `__run_instruction__` is uniform across single-mount and
  multi-mount cases.
  """

  use ExUnit.Case, async: true

  defmodule CounterSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "resolution_counter_slice"
      schema Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)})
    end

    signal_routes do
      route "counter.bump", Jido.Dsl.SlicePathResolutionTest.BumpAction
    end
  end

  defmodule BumpAction do
    @moduledoc false
    use Jido.Action

    action do
      name "bump"
      schema []
    end

    @impl true
    def run(_signal, slice, _opts, _ctx) do
      {:ok, %{slice | count: (slice[:count] || 0) + 1}, []}
    end
  end

  defmodule EscapeAction do
    @moduledoc false
    use Jido.Action

    action do
      name "escape"
      path :counter
      schema []
    end

    @impl true
    def run(_signal, slice, _opts, _ctx) do
      {:ok, Map.put(slice || %{count: 0}, :tagged, true), []}
    end
  end

  defmodule UnboundAction do
    @moduledoc false
    use Jido.Action

    action do
      name "unbound"
      schema []
    end

    @impl true
    def run(_signal, slice, _opts, _ctx) do
      {:ok, Map.put(slice || %{}, :stamped, true), []}
    end
  end

  defmodule ResolutionAgent do
    @moduledoc false
    use Jido.Agent, default_slices: false

    agent do
      name "resolution_agent"
      path :domain
      schema last_action: [type: :atom, default: nil]
    end

    slices do
      slice(:counter, CounterSlice)
    end

    # No agent-level signal_routes — these tests target the FALLBACK chain
    # (action's own `path :foo`, then agent's path) for actions that are
    # not declared in any slice's or the agent's signal_routes. Coverage
    # for design choice #1 ("agent-level routes contribute the agent's
    # own path to the fan-out list") lives in the multi-instance fan-out
    # test suite.
  end

  describe "step 1 — slice that routes to the action wins" do
    test "BumpAction (in CounterSlice's signal_routes) writes to :counter, not :domain" do
      agent = ResolutionAgent.new()
      assert agent.state.counter == %{count: 0}

      {:ok, agent, _dirs} = ResolutionAgent.cmd(agent, BumpAction)
      assert agent.state.counter == %{count: 1}
      # Domain slice is untouched even though the agent declares `path :domain`.
      assert agent.state.domain == %{last_action: nil}
    end

    test "BumpAction has no `path :foo` of its own — resolution comes from the slice mount" do
      assert Jido.Dsl.Action.Info.path(BumpAction) == nil
    end
  end

  describe "step 2 — action's own `path :foo` escape valve" do
    test "EscapeAction (not in any slice's signal_routes) writes to its declared :counter path" do
      agent = ResolutionAgent.new()

      {:ok, agent, _dirs} = ResolutionAgent.cmd(agent, EscapeAction)
      # Action's `path :counter` overrides falling through to the agent's
      # `path :domain`, even though no slice routes to this action.
      assert agent.state.counter[:tagged] == true
      assert agent.state.domain == %{last_action: nil}
    end

    test "EscapeAction has `path :counter` declared as the escape valve" do
      assert Jido.Dsl.Action.Info.path(EscapeAction) == :counter
    end
  end

  describe "step 3 — fall back to agent's own path" do
    test "UnboundAction (no slice routes, no own path) writes to the agent's :domain slice" do
      agent = ResolutionAgent.new()

      {:ok, agent, _dirs} = ResolutionAgent.cmd(agent, UnboundAction)
      assert agent.state.domain[:stamped] == true
      assert agent.state.counter == %{count: 0}
    end
  end

  describe "compile-time lookup table shape" do
    test "slice_paths_for_action maps each slice action module to a list of mount paths" do
      table = Jido.Dsl.Agent.Info.slice_paths_for_action(ResolutionAgent)

      assert is_map(table)
      # Single-mount case is a one-element list — fan-out is uniform.
      assert Map.get(table, BumpAction) == [:counter]
      # The escape-valve action and the unbound action are NOT in the table —
      # they're not routed-to from any slice's signal_routes nor declared on
      # the agent's own signal_routes.
      refute Map.has_key?(table, EscapeAction)
      refute Map.has_key?(table, UnboundAction)
    end
  end
end
