defmodule JidoTest.Identity.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Identity
  alias Jido.Identity.Actions
  alias Jido.Identity.Slice, as: IdentitySlice

  describe "slice metadata" do
    test "name is identity" do
      assert IdentitySlice.name() == "identity"
    end

    test "path is :identity" do
      assert IdentitySlice.path() == :identity
    end

    test "has identity capability" do
      assert :identity in IdentitySlice.capabilities()
    end

    test "exposes Identity.Actions.{Ensure,Evolve,UpdateProfile} via actions/0" do
      action_set = MapSet.new(IdentitySlice.actions())

      assert MapSet.equal?(
               action_set,
               MapSet.new([Actions.Ensure, Actions.Evolve, Actions.UpdateProfile])
             )
    end

    test "schema is bound to Jido.Identity.schema/0" do
      assert IdentitySlice.schema() == Identity.schema()
    end

    test "exposes one signal route per action" do
      route_types =
        IdentitySlice.signal_routes()
        |> Enum.map(fn
          {type, _action} -> type
          {type, _action, _opts} -> type
        end)

      assert "jido.identity.ensure" in route_types
      assert "jido.identity.evolve" in route_types
      assert "jido.identity.update_profile" in route_types
    end
  end

  describe "manifest" do
    test "path is :identity in manifest" do
      manifest = IdentitySlice.manifest()
      assert manifest.path == :identity
    end
  end

  describe "agent integration" do
    defmodule AgentWithIdentity do
      use Jido.Agent

      agent do
        name "identity_slice_test_agent"
      end
    end

    defmodule AgentWithoutIdentity do
      use Jido.Agent,
        default_slices: %{identity: false}

      agent do
        name "identity_slice_test_no_identity"
      end
    end

    test "agent includes identity slice by default" do
      modules = AgentWithIdentity.slices()
      assert Jido.Identity.Slice in modules
    end

    test "agent.state[:identity] starts nil (lazy init)" do
      agent = AgentWithIdentity.new()
      assert Map.get(agent.state, :identity) == nil
    end

    test "agent can disable identity slice" do
      modules = AgentWithoutIdentity.slices()
      refute Jido.Identity.Slice in modules
    end

    test "identity can be attached after creation via Identity.Agent" do
      agent = AgentWithIdentity.new()
      agent = Identity.Agent.ensure(agent)
      assert %Identity{} = Identity.Agent.get(agent)
    end

    test "UpdateProfile action mutates agent.state.identity" do
      agent = AgentWithIdentity.new()

      {:ok, agent, []} =
        AgentWithIdentity.cmd(
          agent,
          {Actions.UpdateProfile, %{profile: %{nickname: "Sam"}}}
        )

      assert agent.state.identity.profile[:nickname] == "Sam"
    end
  end
end
