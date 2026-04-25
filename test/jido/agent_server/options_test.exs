defmodule JidoTest.AgentServer.OptionsTest do
  use ExUnit.Case, async: true

  alias Jido.AgentServer.{Options, ParentRef}

  @base_opts [jido: :test_jido]

  defmodule ValidAgent do
    @moduledoc false
    use Jido.Agent,
      name: "valid_agent",
      path: :domain,
      schema: [value: [type: :integer, default: 0]]
  end

  describe "new/1 with keyword list" do
    test "creates options with agent module" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent])

      assert opts.agent_module == ValidAgent
      assert is_binary(opts.id)
      assert opts.initial_state == %{}
      assert opts.registry == :"Elixir.test_jido.Registry"
      assert opts.register_global == true
      assert opts.on_parent_death == :stop
    end

    test "creates options with custom id" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent, id: "custom-id"])

      assert opts.id == "custom-id"
    end

    test "creates options with initial_state" do
      {:ok, opts} =
        Options.new(@base_opts ++ [agent_module: ValidAgent, initial_state: %{foo: :bar}])

      assert opts.initial_state == %{foo: :bar}
    end

    test "registry is derived from jido instance" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent])

      assert opts.registry == :"Elixir.test_jido.Registry"
    end

    test "explicit registry is preserved when provided" do
      {:ok, opts} =
        Options.new(@base_opts ++ [agent_module: ValidAgent, registry: JidoTest.CustomRegistry])

      assert opts.registry == JidoTest.CustomRegistry
    end

    test "allows disabling global registration" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent, register_global: false])

      assert opts.register_global == false
    end

    test "creates options with default_dispatch" do
      {:ok, opts} =
        Options.new(
          @base_opts ++ [agent_module: ValidAgent, default_dispatch: {:logger, level: :info}]
        )

      assert opts.default_dispatch == {:logger, level: :info}
    end

    test "creates options with on_parent_death" do
      {:ok, opts} =
        Options.new(@base_opts ++ [agent_module: ValidAgent, on_parent_death: :continue])

      assert opts.on_parent_death == :continue
    end

    test "creates options with spawn_fun" do
      spawn_fun = fn _ -> {:ok, self()} end
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent, spawn_fun: spawn_fun])

      assert opts.spawn_fun == spawn_fun
    end
  end

  describe "new/1 with map" do
    test "creates options from map" do
      {:ok, opts} =
        Options.new(%{jido: :test_jido, agent_module: ValidAgent, id: "map-test"})

      assert opts.agent_module == ValidAgent
      assert opts.id == "map-test"
    end
  end

  describe "new!/1" do
    test "returns options on success" do
      opts = Options.new!(@base_opts ++ [agent_module: ValidAgent])

      assert opts.agent_module == ValidAgent
    end

    test "raises on error" do
      assert_raise Jido.Error.ValidationError, fn ->
        Options.new!(@base_opts ++ [agent_module: nil])
      end
    end
  end

  describe "agent module validation" do
    test "requires agent_module" do
      {:error, error} = Options.new(@base_opts)

      assert error.message =~ "agent_module is required"
    end

    test "rejects nil agent_module" do
      {:error, error} = Options.new(@base_opts ++ [agent_module: nil])

      assert error.message =~ "agent_module is required"
    end

    test "rejects module without new function" do
      {:error, error} = Options.new(@base_opts ++ [agent_module: Enum])

      assert error.message =~ "must implement new/0 or new/1"
    end

    test "rejects non-existent module" do
      {:error, error} = Options.new(@base_opts ++ [agent_module: NonExistentModule])

      assert error.message =~ "not found"
    end
  end

  describe "ID handling" do
    test "generates ID when not provided" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent])

      assert is_binary(opts.id)
      assert String.length(opts.id) > 0
    end

    test "uses provided ID" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent, id: "explicit-id"])

      assert opts.id == "explicit-id"
    end

    test "converts atom ID to string" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent, id: :atom_id])

      assert opts.id == "atom_id"
    end

    test "handles empty string ID by generating one" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent, id: ""])

      assert is_binary(opts.id)
      assert opts.id != ""
    end
  end

  describe "parent validation" do
    test "accepts nil parent" do
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent, parent: nil])

      assert opts.parent == nil
    end

    test "accepts ParentRef struct" do
      parent = ParentRef.new!(%{pid: self(), id: "parent-1", tag: :worker})
      {:ok, opts} = Options.new(@base_opts ++ [agent_module: ValidAgent, parent: parent])

      assert opts.parent == parent
    end

    test "accepts parent as map and converts to ParentRef" do
      {:ok, opts} =
        Options.new(
          @base_opts ++
            [agent_module: ValidAgent, parent: %{pid: self(), id: "parent-2", tag: :child}]
        )

      assert %ParentRef{} = opts.parent
      assert opts.parent.id == "parent-2"
      assert opts.parent.tag == :child
    end

    test "rejects invalid parent" do
      {:error, error} = Options.new(@base_opts ++ [agent_module: ValidAgent, parent: "invalid"])

      assert error.message =~ "parent"
    end
  end
end
