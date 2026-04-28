defmodule JidoTest.Identity.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Identity
  alias Jido.Identity.Slice, as: IdentitySlice

  describe "slice metadata" do
    test "name is identity" do
      assert IdentitySlice.name() == "identity"
    end

    test "path is :identity" do
      assert IdentitySlice.path() == :identity
    end

    test "is singleton" do
      assert IdentitySlice.singleton?() == true
    end

    test "has identity capability" do
      assert :identity in IdentitySlice.capabilities()
    end

    test "has no actions" do
      assert IdentitySlice.actions() == []
    end

    test "schema is nil (no auto-initialization)" do
      assert IdentitySlice.schema() == nil
    end
  end

  describe "manifest" do
    test "singleton is true in manifest" do
      manifest = IdentitySlice.manifest()
      assert manifest.singleton == true
    end

    test "path is :identity in manifest" do
      manifest = IdentitySlice.manifest()
      assert manifest.path == :identity
    end
  end

  describe "agent integration" do
    defmodule AgentWithIdentity do
      use Jido.Agent, name: "identity_slice_test_agent", path: :domain
    end

    defmodule AgentWithoutIdentity do
      use Jido.Agent,
        name: "identity_slice_test_no_identity",
        path: :domain,
        default_slices: %{identity: false}
    end

    test "agent includes identity slice by default" do
      modules = AgentWithIdentity.slices()
      assert Jido.Identity.Slice in modules
    end

    test "agent.state[:identity] starts nil (no auto-init)" do
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
  end
end
