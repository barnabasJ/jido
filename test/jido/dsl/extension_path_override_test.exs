defmodule Jido.Dsl.ExtensionPathOverrideTest do
  @moduledoc """
  End-to-end tests for the per-contributed-section `path:` override
  introduced by `Jido.Slice.Extension` (task 0041).

  The override lets a host rename a contributed slice's mount path:

      use Jido.Agent, extensions: [Jido.Memory.Slice]

      memory do
        path :short_term
      end

  When the contributed section's `:path` option is set, the slice
  instance attached to the host mounts at the override; otherwise it
  falls back to the slice's declared `path/0`.
  """

  use ExUnit.Case, async: true

  alias Jido.Dsl.Agent.Info, as: AgentInfo
  alias Jido.Slice.Instance, as: SliceInstance

  defmodule HostWithMemoryOverride do
    @moduledoc false
    use Jido.Agent,
      extensions: [Jido.Memory.Slice],
      default_slices: false

    agent do
      name "host_memory_override"
    end

    memory do
      path :short_term
    end
  end

  defmodule HostWithoutMemoryOverride do
    @moduledoc false
    use Jido.Agent,
      extensions: [Jido.Memory.Slice],
      default_slices: false

    agent do
      name "host_memory_default"
    end
  end

  describe "contributed-section path override" do
    test "renames the slice's mount path when set" do
      instances = AgentInfo.slice_instances(HostWithMemoryOverride)
      memory = Enum.find(instances, &(&1.module == Jido.Memory.Slice))

      assert memory
      assert memory.path == :short_term
    end

    test "falls back to the slice's declared path when not set" do
      instances = AgentInfo.slice_instances(HostWithoutMemoryOverride)
      memory = Enum.find(instances, &(&1.module == Jido.Memory.Slice))

      assert memory
      assert memory.path == :memory
    end
  end

  describe "Slice.Instance.new/1 with :__path_override__" do
    test "honours the override key" do
      instance =
        SliceInstance.new({Jido.Memory.Slice, %{__path_override__: :short_term}})

      assert instance.path == :short_term
      assert instance.module == Jido.Memory.Slice
    end

    test "ignores the absence of the override key" do
      instance = SliceInstance.new(Jido.Memory.Slice)
      assert instance.path == :memory
    end

    test "strips the override key before resolving config" do
      instance =
        SliceInstance.new({Jido.Memory.Slice, %{__path_override__: :renamed}})

      refute Map.has_key?(instance.config, :__path_override__)
    end
  end
end
