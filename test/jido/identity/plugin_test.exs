defmodule JidoTest.Identity.PluginTest do
  use ExUnit.Case, async: true

  alias Jido.Identity
  alias Jido.Identity.Plugin, as: IdentityPlugin

  describe "plugin metadata" do
    test "name is identity" do
      assert IdentityPlugin.name() == "identity"
    end

    test "state_key is :identity" do
      assert IdentityPlugin.path() == :identity
    end

    test "is singleton" do
      assert IdentityPlugin.singleton?() == true
    end

    test "has identity capability" do
      assert :identity in IdentityPlugin.capabilities()
    end

    test "has no actions" do
      assert IdentityPlugin.actions() == []
    end

    test "schema is nil (no auto-initialization)" do
      assert IdentityPlugin.schema() == nil
    end
  end

  describe "manifest" do
    test "singleton is true in manifest" do
      manifest = IdentityPlugin.manifest()
      assert manifest.singleton == true
    end

    test "state_key is :identity in manifest" do
      manifest = IdentityPlugin.manifest()
      assert manifest.path == :identity
    end
  end

  describe "agent integration" do
    defmodule AgentWithIdentity do
      use Jido.Agent, name: "identity_plugin_test_agent", path: :domain
    end

    defmodule AgentWithoutIdentity do
      use Jido.Agent,
        name: "identity_plugin_test_no_identity",
        path: :domain,
        default_plugins: %{identity: false}
    end

    test "agent includes identity plugin by default" do
      modules = AgentWithIdentity.plugins()
      assert Jido.Identity.Plugin in modules
    end

    test "agent.state[:identity] starts nil (no auto-init)" do
      agent = AgentWithIdentity.new()
      assert Map.get(agent.state, :identity) == nil
    end

    test "agent can disable identity plugin" do
      modules = AgentWithoutIdentity.plugins()
      refute Jido.Identity.Plugin in modules
    end

    test "identity can be attached after creation via Identity.Agent" do
      agent = AgentWithIdentity.new()
      agent = Identity.Agent.ensure(agent)
      assert %Identity{} = Identity.Agent.get(agent)
    end

    test "cannot alias identity plugin" do
      assert_raise ArgumentError, ~r/Cannot alias singleton plugin/, fn ->
        Jido.Plugin.Instance.new({Jido.Identity.Plugin, as: :my_identity})
      end
    end
  end
end
