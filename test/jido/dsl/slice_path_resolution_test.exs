defmodule Jido.Dsl.SlicePathResolutionTest do
  @moduledoc """
  Targeted coverage for the post-task-0053 `__resolve_slice_path__/1`
  resolution order:

    1. The slice that routes to the action via its `signal_routes` (the
       compile-time `:slice_path_for_action` lookup table).
    2. The action's own `path :foo` escape valve (for ad-hoc actions on
       the agent's own `signal_routes` that aren't owned by any slice's
       routes).
    3. The agent's own `path :foo` (the `agent do … end` slice).

  Pre-task-0053 only step 2 and step 3 existed; step 1 is the new
  behaviour task 0053 introduces. Step 2 is preserved as an explicit
  escape valve so test fixtures and in-turn pod-mutation actions on the
  agent's own routes can still bind a slice path without going through a
  slice's `signal_routes`.
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

    signal_routes do
      route "agent.escape", Jido.Dsl.SlicePathResolutionTest.EscapeAction
      route "agent.unbound", Jido.Dsl.SlicePathResolutionTest.UnboundAction
    end
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
    test "slice_path_for_action maps each slice action module to its mount path" do
      table = Spark.Dsl.Extension.get_persisted(ResolutionAgent, :slice_path_for_action)

      assert is_map(table)
      assert Map.get(table, BumpAction) == :counter
      # The escape-valve action and the unbound action are NOT in the table —
      # they're not routed-to from any slice's signal_routes.
      refute Map.has_key?(table, EscapeAction)
      refute Map.has_key?(table, UnboundAction)
    end
  end
end
