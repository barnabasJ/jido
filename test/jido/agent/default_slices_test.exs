defmodule JidoTest.Agent.DefaultSlicesTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.DefaultSlices

  defmodule FakeMemorySlice do
    @moduledoc false
    use Jido.Slice,
      name: "fake_memory",
      path: :memory,
      actions: [JidoTest.PluginTestAction],
      singleton: true
  end

  defmodule FakeThreadSlice do
    @moduledoc false
    use Jido.Slice,
      name: "fake_thread",
      path: :thread,
      actions: [JidoTest.PluginTestAction],
      singleton: true
  end

  defmodule ReplacementMemorySlice do
    @moduledoc false
    use Jido.Slice,
      name: "replacement_memory",
      path: :memory,
      actions: [JidoTest.PluginTestAction],
      singleton: true
  end

  defmodule UserSlice do
    @moduledoc false
    use Jido.Slice,
      name: "user_slice",
      path: :user_stuff,
      actions: [JidoTest.PluginTestAction]
  end

  describe "package_defaults/0" do
    test "returns list with Thread.Slice, Identity.Slice, and Memory.Slice" do
      assert DefaultSlices.package_defaults() == [
               Jido.Thread.Slice,
               Jido.Identity.Slice,
               Jido.Memory.Slice
             ]
    end
  end

  describe "apply_agent_overrides/2" do
    test "nil overrides returns defaults unchanged" do
      defaults = [FakeMemorySlice, FakeThreadSlice]
      assert DefaultSlices.apply_agent_overrides(defaults, nil) == defaults
    end

    test "false disables all defaults" do
      defaults = [FakeMemorySlice, FakeThreadSlice]
      assert DefaultSlices.apply_agent_overrides(defaults, false) == []
    end

    test "empty map returns defaults unchanged" do
      defaults = [FakeMemorySlice, FakeThreadSlice]
      assert DefaultSlices.apply_agent_overrides(defaults, %{}) == defaults
    end

    test "exclude a default by state_key" do
      defaults = [FakeMemorySlice, FakeThreadSlice]
      result = DefaultSlices.apply_agent_overrides(defaults, %{thread: false})
      assert result == [FakeMemorySlice]
    end

    test "replace a default with another module" do
      defaults = [FakeMemorySlice, FakeThreadSlice]

      result =
        DefaultSlices.apply_agent_overrides(defaults, %{memory: ReplacementMemorySlice})

      assert result == [ReplacementMemorySlice, FakeThreadSlice]
    end

    test "replace a default with module and config tuple" do
      defaults = [FakeMemorySlice, FakeThreadSlice]

      result =
        DefaultSlices.apply_agent_overrides(defaults, %{
          memory: {ReplacementMemorySlice, %{timeout: 5000}}
        })

      assert result == [{ReplacementMemorySlice, %{timeout: 5000}}, FakeThreadSlice]
    end

    test "combine exclude and replace" do
      defaults = [FakeMemorySlice, FakeThreadSlice]
      overrides = %{thread: false, memory: ReplacementMemorySlice}
      result = DefaultSlices.apply_agent_overrides(defaults, overrides)
      assert result == [ReplacementMemorySlice]
    end

    test "invalid override key raises CompileError" do
      defaults = [FakeMemorySlice, FakeThreadSlice]

      assert_raise CompileError, ~r/Invalid default_slices override keys/, fn ->
        DefaultSlices.apply_agent_overrides(defaults, %{nonexistent: false})
      end
    end

    test "handles defaults with config tuples" do
      defaults = [{FakeMemorySlice, %{opt: true}}, FakeThreadSlice]
      result = DefaultSlices.apply_agent_overrides(defaults, %{thread: false})
      assert result == [{FakeMemorySlice, %{opt: true}}]
    end

    test "replace a default that has config tuple" do
      defaults = [{FakeMemorySlice, %{opt: true}}, FakeThreadSlice]

      result =
        DefaultSlices.apply_agent_overrides(defaults, %{memory: ReplacementMemorySlice})

      assert result == [ReplacementMemorySlice, FakeThreadSlice]
    end

    test "exclude all defaults individually" do
      defaults = [FakeMemorySlice, FakeThreadSlice]
      overrides = %{memory: false, thread: false}
      result = DefaultSlices.apply_agent_overrides(defaults, overrides)
      assert result == []
    end

    test "single default list" do
      defaults = [FakeMemorySlice]
      result = DefaultSlices.apply_agent_overrides(defaults, %{memory: false})
      assert result == []
    end
  end

  describe "agent macro integration" do
    test "agent with no default_slices option gets framework defaults" do
      defmodule AgentNoDefaults do
        use Jido.Agent, name: "ds_agent_no_defaults", path: :domain
      end

      instances = AgentNoDefaults.slice_instances()
      assert length(instances) == 3
      modules = Enum.map(instances, & &1.module)
      assert Jido.Thread.Slice in modules
      assert Jido.Identity.Slice in modules
      assert Jido.Memory.Slice in modules
    end

    test "agent with default_slices: false gets no defaults" do
      defmodule AgentDisableDefaults do
        use Jido.Agent,
          name: "ds_agent_disable_defaults",
          path: :domain,
          default_slices: false
      end

      assert AgentDisableDefaults.slice_instances() == []
    end

    test "agent with slices still gets them when default_slices is false" do
      defmodule AgentUserSlicesOnly do
        use Jido.Agent,
          name: "ds_agent_user_only",
          path: :domain,
          default_slices: false,
          slices: [UserSlice]
      end

      instances = AgentUserSlicesOnly.slice_instances()
      assert length(instances) == 1
      assert hd(instances).module == UserSlice
    end

    test "agent with jido: option resolves defaults from instance" do
      defmodule FakeJido do
        def __default_slices__, do: [FakeMemorySlice]
      end

      defmodule AgentWithJido do
        use Jido.Agent,
          name: "ds_agent_with_jido",
          path: :domain,
          jido: FakeJido
      end

      instances = AgentWithJido.slice_instances()
      assert length(instances) == 1
      assert hd(instances).module == FakeMemorySlice
    end

    test "agent with jido: and default_slices override map" do
      defmodule FakeJido2 do
        def __default_slices__, do: [FakeMemorySlice, FakeThreadSlice]
      end

      defmodule AgentWithJidoOverride do
        use Jido.Agent,
          name: "ds_agent_jido_override",
          path: :domain,
          jido: FakeJido2,
          default_slices: %{thread: false}
      end

      instances = AgentWithJidoOverride.slice_instances()
      assert length(instances) == 1
      assert hd(instances).module == FakeMemorySlice
    end

    test "agent with jido: and replacement in default_slices" do
      defmodule FakeJido3 do
        def __default_slices__, do: [FakeMemorySlice, FakeThreadSlice]
      end

      defmodule AgentWithReplacement do
        use Jido.Agent,
          name: "ds_agent_replacement",
          path: :domain,
          jido: FakeJido3,
          default_slices: %{memory: ReplacementMemorySlice}
      end

      instances = AgentWithReplacement.slice_instances()
      modules = Enum.map(instances, & &1.module)
      assert ReplacementMemorySlice in modules
      assert FakeThreadSlice in modules
      refute FakeMemorySlice in modules
    end

    test "defaults mount before user slices" do
      defmodule FakeJido4 do
        def __default_slices__, do: [FakeMemorySlice]
      end

      defmodule AgentMountOrder do
        use Jido.Agent,
          name: "ds_agent_mount_order",
          path: :domain,
          jido: FakeJido4,
          slices: [UserSlice]
      end

      instances = AgentMountOrder.slice_instances()
      assert length(instances) == 2
      assert Enum.at(instances, 0).module == FakeMemorySlice
      assert Enum.at(instances, 1).module == UserSlice
    end
  end
end
