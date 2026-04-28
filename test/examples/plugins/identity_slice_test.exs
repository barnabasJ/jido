defmodule JidoExampleTest.IdentitySliceTest do
  @moduledoc """
  Example test demonstrating Identity as a default slice.

  This test shows:
  - Every agent gets `Jido.Identity.Slice` automatically (default singleton slice)
  - Using `Jido.Identity.Agent` and related helpers: `ensure/2`, profile management
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
  alias Jido.Identity.Agent, as: IdentityAgent
  alias Jido.Identity.Profile

  # ===========================================================================
  # CUSTOM IDENTITY SLICE
  # ===========================================================================

  defmodule CustomIdentitySlice do
    @moduledoc false
    use Jido.Slice,
      name: "custom_identity",
      path: :identity,
      actions: [],
      singleton: true,
      description: "Custom identity slice override."
  end

  # ===========================================================================
  # AGENTS
  # ===========================================================================

  defmodule WebCrawlerAgent do
    @moduledoc false
    use Jido.Agent,
      name: "web_crawler",
      path: :domain,
      description: "Agent with identity for capability-based routing",
      schema: []

    def signal_routes(_ctx) do
      [
        {"evolve", Jido.Identity.Actions.Evolve}
      ]
    end
  end

  defmodule PreConfiguredAgent do
    @moduledoc false
    use Jido.Agent,
      name: "pre_configured",
      path: :domain,
      description: "Agent with custom identity slice that overrides the default",
      default_slices: %{
        identity: CustomIdentitySlice
      },
      schema: [
        status: [type: :atom, default: :idle]
      ]
  end

  defmodule NoIdentityAgent do
    @moduledoc false
    use Jido.Agent,
      name: "no_identity",
      path: :domain,
      description: "Agent with identity slice disabled",
      default_slices: %{identity: false},
      schema: [
        value: [type: :integer, default: 0]
      ]
  end

  # ===========================================================================
  # TESTS: Default identity slice
  # ===========================================================================

  describe "identity slice is a default singleton" do
    test "new agent has no identity until initialized on demand" do
      agent = WebCrawlerAgent.new()

      refute IdentityAgent.has_identity?(agent)
    end

    test "IdentityAgent.ensure initializes identity on demand" do
      agent = WebCrawlerAgent.new()

      agent =
        IdentityAgent.ensure(agent,
          profile: %{age: 0, origin: :configured}
        )

      assert IdentityAgent.has_identity?(agent)
      assert Profile.age(agent) == 0
      assert Profile.get(agent, :origin) == :configured
    end
  end

  describe "snapshot for sharing identity" do
    test "snapshot includes profile data" do
      agent =
        WebCrawlerAgent.new()
        |> IdentityAgent.ensure(profile: %{age: 3, generation: 2, origin: :spawned})

      snapshot = IdentityAgent.snapshot(agent)

      assert snapshot.profile[:age] == 3
      assert snapshot.profile[:generation] == 2
      assert snapshot.profile[:origin] == :spawned
    end

    test "snapshot returns nil when no identity" do
      agent = WebCrawlerAgent.new()
      assert IdentityAgent.snapshot(agent) == nil
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
      agent =
        WebCrawlerAgent.new()
        |> IdentityAgent.ensure(profile: %{age: 0})

      {:ok, agent, []} = WebCrawlerAgent.cmd(agent, {Jido.Identity.Actions.Evolve, %{years: 3}})

      assert Profile.age(agent) == 3
    end

    test "evolution preserves identity data" do
      agent =
        WebCrawlerAgent.new()
        |> IdentityAgent.ensure(profile: %{age: 0, origin: :test})

      {:ok, agent, []} = WebCrawlerAgent.cmd(agent, {Jido.Identity.Actions.Evolve, %{years: 5}})

      assert Profile.age(agent) == 5
      assert Profile.get(agent, :origin) == :test
    end
  end

  describe "replacing identity slice with custom implementation" do
    test "custom slice replaces default Identity.Slice" do
      modules = PreConfiguredAgent.slices()

      assert CustomIdentitySlice in modules
      refute Jido.Identity.Slice in modules
    end
  end

  describe "disabling identity slice" do
    test "agent with identity disabled has no identity capability" do
      agent = NoIdentityAgent.new()

      refute IdentityAgent.has_identity?(agent)
      refute Map.has_key?(agent.state, :identity)

      modules = NoIdentityAgent.slices()
      refute Jido.Identity.Slice in modules
    end
  end
end
