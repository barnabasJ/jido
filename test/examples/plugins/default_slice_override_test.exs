defmodule JidoExampleTest.DefaultSliceOverrideTest do
  @moduledoc """
  Example test demonstrating how to override, replace, or disable default slices.

  This test shows:
  - Default slices (like Jido.Thread.Slice) are auto-included in all agents
  - Replacing a default slice with a custom implementation via `default_slices: %{}`
  - Passing config to a replacement slice
  - Disabling a specific default slice
  - Disabling all default slices entirely

  Run with: mix test --include example
  """
  use JidoTest.Case, async: true

  @moduletag :example
  @moduletag timeout: 15_000

  # ===========================================================================
  # SLICES: Custom replacement for Jido.Thread.Slice
  # ===========================================================================

  defmodule CustomThreadSlice do
    @moduledoc false
    use Jido.Slice,
      name: "custom_thread",
      path: :thread,
      actions: [],
      singleton: true,
      schema:
        Zoi.object(%{
          custom_initialized: Zoi.boolean() |> Zoi.default(true),
          max_entries: Zoi.integer() |> Zoi.default(500)
        }),
      description: "Custom replacement for the default thread slice."
  end

  # ===========================================================================
  # AGENTS: Various default_slices configurations
  # ===========================================================================

  defmodule DefaultAgent do
    @moduledoc false
    use Jido.Agent,
      name: "default_agent",
      path: :domain,
      description: "Plain agent — gets Thread.Slice automatically",
      schema: [
        status: [type: :atom, default: :idle]
      ]
  end

  defmodule OverriddenAgent do
    @moduledoc false
    use Jido.Agent,
      name: "overridden_agent",
      path: :domain,
      description: "Replaces Thread.Slice with CustomThreadSlice",
      schema: [
        status: [type: :atom, default: :idle]
      ],
      default_slices: %{thread: CustomThreadSlice}
  end

  defmodule ConfiguredAgent do
    @moduledoc false
    use Jido.Agent,
      name: "configured_agent",
      path: :domain,
      description: "Replaces Thread.Slice with CustomThreadSlice + config",
      schema: [
        status: [type: :atom, default: :idle]
      ],
      default_slices: %{thread: {CustomThreadSlice, %{max_entries: 50}}}
  end

  defmodule DisabledAgent do
    @moduledoc false
    use Jido.Agent,
      name: "disabled_agent",
      path: :domain,
      description: "Disables only the thread default slice",
      schema: [
        status: [type: :atom, default: :idle]
      ],
      default_slices: %{thread: false}
  end

  defmodule BareAgent do
    @moduledoc false
    use Jido.Agent,
      name: "bare_agent",
      path: :domain,
      description: "Disables all default slices entirely",
      schema: [
        status: [type: :atom, default: :idle]
      ],
      default_slices: false
  end

  # ===========================================================================
  # TESTS
  # ===========================================================================

  describe "default slices are auto-included" do
    test "default agent includes Thread.Slice and Identity.Slice in slices" do
      modules = DefaultAgent.slices()

      assert Jido.Thread.Slice in modules
      assert Jido.Identity.Slice in modules
    end
  end

  describe "replacing a default slice" do
    test "overridden agent uses CustomThreadSlice instead of Thread.Slice" do
      agent = OverriddenAgent.new()
      modules = OverriddenAgent.slices()

      assert CustomThreadSlice in modules
      refute Jido.Thread.Slice in modules
      assert agent.state.thread.custom_initialized == true
      assert agent.state.thread.max_entries == 500
    end

    test "configured agent receives config when seeding initial slice state" do
      agent = ConfiguredAgent.new()

      assert agent.state.thread.custom_initialized == true
      assert agent.state.thread.max_entries == 50
    end
  end

  describe "disabling default slices" do
    test "disabled agent does not have :thread in state" do
      agent = DisabledAgent.new()
      modules = DisabledAgent.slices()

      refute Jido.Thread.Slice in modules
      refute Map.has_key?(agent.state, :thread)
    end

    test "bare agent with all defaults disabled does not have :thread" do
      agent = BareAgent.new()

      assert BareAgent.slice_instances() == []
      refute Map.has_key?(agent.state, :thread)
    end
  end

  describe "agents with overridden defaults still work normally" do
    test "default and overridden agents both initialize via new()" do
      default = DefaultAgent.new(state: %{status: :running})
      overridden = OverriddenAgent.new(state: %{status: :running})

      assert default.state.domain.status == :running
      assert overridden.state.domain.status == :running

      assert overridden.state.thread.custom_initialized == true
    end
  end
end
