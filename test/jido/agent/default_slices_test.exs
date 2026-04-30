defmodule JidoTest.Agent.DefaultSlicesTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.DefaultSlices
  alias Jido.Dsl.Agent.Info, as: AgentInfo

  defmodule FakeMemorySlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "fake_memory"
      path :memory
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "fake_memory.noop", JidoTest.PluginTestAction
    end
  end

  defmodule FakeThreadSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "fake_thread"
      path :thread
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "fake_thread.noop", JidoTest.PluginTestAction
    end
  end

  defmodule ReplacementMemorySlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "replacement_memory"
      path :memory
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "replacement_memory.noop", JidoTest.PluginTestAction
    end
  end

  defmodule UserSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "user_slice"
      path :user_stuff
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "user_slice.noop", JidoTest.PluginTestAction
    end
  end

  describe "package_defaults/0" do
    test "returns list of {path, module} tuples for Thread / Identity / Memory slices" do
      assert DefaultSlices.package_defaults() == [
               {:thread, Jido.Thread.Slice},
               {:identity, Jido.Identity.Slice},
               {:memory, Jido.Memory.Slice}
             ]
    end
  end

  describe "apply_agent_overrides/2" do
    test "nil overrides returns defaults unchanged" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]
      assert DefaultSlices.apply_agent_overrides(defaults, nil) == defaults
    end

    test "false disables all defaults" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]
      assert DefaultSlices.apply_agent_overrides(defaults, false) == []
    end

    test "empty map returns defaults unchanged" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]
      assert DefaultSlices.apply_agent_overrides(defaults, %{}) == defaults
    end

    test "exclude a default by path" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]
      result = DefaultSlices.apply_agent_overrides(defaults, %{thread: false})
      assert result == [{:memory, FakeMemorySlice}]
    end

    test "replace a default with another module" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]

      result =
        DefaultSlices.apply_agent_overrides(defaults, %{memory: ReplacementMemorySlice})

      assert result == [{:memory, ReplacementMemorySlice}, {:thread, FakeThreadSlice}]
    end

    test "replace a default with module and config tuple" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]

      result =
        DefaultSlices.apply_agent_overrides(defaults, %{
          memory: {ReplacementMemorySlice, %{timeout: 5000}}
        })

      assert result == [
               {:memory, ReplacementMemorySlice, %{timeout: 5000}},
               {:thread, FakeThreadSlice}
             ]
    end

    test "combine exclude and replace" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]
      overrides = %{thread: false, memory: ReplacementMemorySlice}
      result = DefaultSlices.apply_agent_overrides(defaults, overrides)
      assert result == [{:memory, ReplacementMemorySlice}]
    end

    test "invalid override key raises CompileError" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]

      assert_raise CompileError, ~r/Invalid default_slices override keys/, fn ->
        DefaultSlices.apply_agent_overrides(defaults, %{nonexistent: false})
      end
    end

    test "handles defaults with config tuples" do
      defaults = [{:memory, FakeMemorySlice, %{opt: true}}, {:thread, FakeThreadSlice}]
      result = DefaultSlices.apply_agent_overrides(defaults, %{thread: false})
      assert result == [{:memory, FakeMemorySlice, %{opt: true}}]
    end

    test "replace a default that has config tuple" do
      defaults = [{:memory, FakeMemorySlice, %{opt: true}}, {:thread, FakeThreadSlice}]

      result =
        DefaultSlices.apply_agent_overrides(defaults, %{memory: ReplacementMemorySlice})

      assert result == [{:memory, ReplacementMemorySlice}, {:thread, FakeThreadSlice}]
    end

    test "exclude all defaults individually" do
      defaults = [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]
      overrides = %{memory: false, thread: false}
      result = DefaultSlices.apply_agent_overrides(defaults, overrides)
      assert result == []
    end

    test "single default list" do
      defaults = [{:memory, FakeMemorySlice}]
      result = DefaultSlices.apply_agent_overrides(defaults, %{memory: false})
      assert result == []
    end
  end

  describe "agent macro integration" do
    test "agent with no default_slices option gets framework defaults" do
      defmodule AgentNoDefaults do
        use Jido.Agent

        agent do
          name "ds_agent_no_defaults"
        end
      end

      instances = AgentInfo.slice_instances(AgentNoDefaults)
      assert length(instances) == 3
      modules = Enum.map(instances, & &1.module)
      assert Jido.Thread.Slice in modules
      assert Jido.Identity.Slice in modules
      assert Jido.Memory.Slice in modules
    end

    test "agent with default_slices: false gets no defaults" do
      defmodule AgentDisableDefaults do
        use Jido.Agent,
          default_slices: false

        agent do
          name "ds_agent_disable_defaults"
        end
      end

      assert AgentInfo.slice_instances(AgentDisableDefaults) == []
    end

    test "agent with slices still gets them when default_slices is false" do
      defmodule AgentUserSlicesOnly do
        use Jido.Agent, default_slices: false

        agent do
          name "ds_agent_user_only"
        end

        slices do
          slice(:user_stuff, UserSlice)
        end
      end

      instances = AgentInfo.slice_instances(AgentUserSlicesOnly)
      assert length(instances) == 1
      assert hd(instances).module == UserSlice
    end

    test "agent with jido: option resolves defaults from instance" do
      defmodule FakeJido do
        def __default_slices__, do: [{:memory, FakeMemorySlice}]
      end

      defmodule AgentWithJido do
        use Jido.Agent,
          jido: FakeJido

        agent do
          name "ds_agent_with_jido"
        end
      end

      instances = AgentInfo.slice_instances(AgentWithJido)
      assert length(instances) == 1
      assert hd(instances).module == FakeMemorySlice
    end

    test "agent with jido: and default_slices override map" do
      defmodule FakeJido2 do
        def __default_slices__, do: [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]
      end

      defmodule AgentWithJidoOverride do
        use Jido.Agent,
          jido: FakeJido2,
          default_slices: %{thread: false}

        agent do
          name "ds_agent_jido_override"
        end
      end

      instances = AgentInfo.slice_instances(AgentWithJidoOverride)
      assert length(instances) == 1
      assert hd(instances).module == FakeMemorySlice
    end

    test "agent with jido: and replacement in default_slices" do
      defmodule FakeJido3 do
        def __default_slices__, do: [{:memory, FakeMemorySlice}, {:thread, FakeThreadSlice}]
      end

      defmodule AgentWithReplacement do
        use Jido.Agent,
          jido: FakeJido3,
          default_slices: %{memory: ReplacementMemorySlice}

        agent do
          name "ds_agent_replacement"
        end
      end

      instances = AgentInfo.slice_instances(AgentWithReplacement)
      modules = Enum.map(instances, & &1.module)
      assert ReplacementMemorySlice in modules
      assert FakeThreadSlice in modules
      refute FakeMemorySlice in modules
    end

    test "defaults mount before user slices" do
      defmodule FakeJido4 do
        def __default_slices__, do: [{:memory, FakeMemorySlice}]
      end

      defmodule AgentMountOrder do
        use Jido.Agent, jido: FakeJido4

        agent do
          name "ds_agent_mount_order"
        end

        slices do
          slice(:user_stuff, UserSlice)
        end
      end

      instances = AgentInfo.slice_instances(AgentMountOrder)
      assert length(instances) == 2
      assert Enum.at(instances, 0).module == FakeMemorySlice
      assert Enum.at(instances, 1).module == UserSlice
    end
  end
end
