defmodule JidoExampleTest.IdentitySliceTest do
  @moduledoc """
  Example test demonstrating Identity as a default slice.

  This test shows:
  - Every agent gets `Jido.Identity.Slice` automatically (default slice)
  - Initializing identity through `Jido.Identity.Actions.Ensure` via `cmd/2`
  - Reading identity directly off `agent.state[:identity]`
  - Snapshot for sharing identity with other agents
  - Evolving identity over simulated time via `Jido.Identity.evolve/2` and the Evolve action
  - Replacing the default Identity.Slice with a custom implementation
  - Disabling the identity slice with `default_slices: %{identity: false}`

  Run with: mix test --include example
  """
  use JidoTest.Case, async: false

  @moduletag :example
  @moduletag timeout: 15_000

  alias Jido.Identity

  # ===========================================================================
  # CUSTOM IDENTITY SLICE
  # ===========================================================================

  defmodule CustomIdentitySlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "custom_identity"
      description "Custom identity slice override."
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "custom_identity.noop", JidoTest.PluginTestAction
    end
  end

  # ===========================================================================
  # AGENTS
  # ===========================================================================

  defmodule WebCrawlerAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "web_crawler"
      description "Agent with identity for capability-based routing"
    end

    signal_routes do
      route "evolve", Jido.Identity.Actions.Evolve
    end
  end

  defmodule PreConfiguredAgent do
    @moduledoc false
    use Jido.Agent,
      default_slices: %{identity: CustomIdentitySlice}

    agent do
      name "pre_configured"
      path :domain
      description "Agent with custom identity slice that overrides the default"
      schema status: [type: :atom, default: :idle]
    end
  end

  defmodule NoIdentityAgent do
    @moduledoc false
    use Jido.Agent,
      default_slices: %{identity: false}

    agent do
      name "no_identity"
      path :domain
      description "Agent with identity slice disabled"
      schema value: [type: :integer, default: 0]
    end
  end

  # ===========================================================================
  # TESTS: Default identity slice
  # ===========================================================================

  describe "identity slice is a default slice" do
    test "new agent has no identity until initialized on demand" do
      agent = WebCrawlerAgent.new()

      assert is_nil(agent.state[:identity])
    end

    test "Ensure action initializes identity on demand" do
      agent = WebCrawlerAgent.new()

      {:ok, agent, []} =
        WebCrawlerAgent.cmd(
          agent,
          {Jido.Identity.Actions.Ensure, %{profile: %{age: 0, origin: :configured}}}
        )

      assert %Identity{} = agent.state[:identity]
      assert agent.state.identity.profile[:age] == 0
      assert agent.state.identity.profile[:origin] == :configured
    end
  end

  describe "snapshot for sharing identity" do
    test "snapshot includes profile data" do
      agent = WebCrawlerAgent.new()

      {:ok, agent, []} =
        WebCrawlerAgent.cmd(
          agent,
          {Jido.Identity.Actions.Ensure, %{profile: %{age: 3, generation: 2, origin: :spawned}}}
        )

      snapshot = Identity.snapshot(agent.state.identity)

      assert snapshot.profile[:age] == 3
      assert snapshot.profile[:generation] == 2
      assert snapshot.profile[:origin] == :spawned
    end

    test "no identity is set when ensure is not invoked" do
      agent = WebCrawlerAgent.new()
      assert is_nil(agent.state[:identity])
    end
  end

  describe "evolution" do
    test "evolve identity with pure function" do
      identity = Identity.new(profile: %{age: 0})

      evolved = Identity.evolve(identity, years: 2)
      assert evolved.profile[:age] == 2
      assert evolved.rev == 1

      evolved = Identity.evolve(evolved, days: 730)
      assert evolved.profile[:age] == 4
      assert evolved.rev == 2
    end

    test "evolve via action" do
      agent = WebCrawlerAgent.new()

      {:ok, agent, []} =
        WebCrawlerAgent.cmd(
          agent,
          {Jido.Identity.Actions.Ensure, %{profile: %{age: 0}}}
        )

      {:ok, agent, []} =
        WebCrawlerAgent.cmd(agent, {Jido.Identity.Actions.Evolve, %{years: 3}})

      assert agent.state.identity.profile[:age] == 3
    end

    test "evolution preserves identity data" do
      agent = WebCrawlerAgent.new()

      {:ok, agent, []} =
        WebCrawlerAgent.cmd(
          agent,
          {Jido.Identity.Actions.Ensure, %{profile: %{age: 0, origin: :test}}}
        )

      {:ok, agent, []} =
        WebCrawlerAgent.cmd(agent, {Jido.Identity.Actions.Evolve, %{years: 5}})

      assert agent.state.identity.profile[:age] == 5
      assert agent.state.identity.profile[:origin] == :test
    end
  end

  describe "replacing identity slice with custom implementation" do
    test "custom slice replaces default Identity.Slice" do
      modules = Jido.Dsl.Agent.Info.slices(PreConfiguredAgent)

      assert CustomIdentitySlice in modules
      refute Jido.Identity.Slice in modules
    end
  end

  describe "disabling identity slice" do
    test "agent with identity disabled has no identity capability" do
      agent = NoIdentityAgent.new()

      assert is_nil(agent.state[:identity])
      refute Map.has_key?(agent.state, :identity)

      modules = Jido.Dsl.Agent.Info.slices(NoIdentityAgent)
      refute Jido.Identity.Slice in modules
    end
  end
end
