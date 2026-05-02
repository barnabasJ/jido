defmodule Jido.Dsl.ExtensionPathOverrideTest do
  @moduledoc """
  End-to-end tests for the per-contributed-section `path:` override
  introduced by `Jido.Slice.Extension` (task 0041).

  The override lets a host rename a contributed slice's mount path:

      use Jido.Agent, extensions: [Jido.Slices.Memory]

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

  # The path-override mechanism is now `slices do slice :path, Slice end`
  # on the host agent. The contributed-section `path:` field that used to
  # carry path was removed in task 0053 — paths are owned by the agent.
  defmodule HostWithMemoryOverride do
    @moduledoc false
    use Jido.Agent, default_slices: false

    agent do
      name "host_memory_override"
    end

    slices do
      slice(:short_term, Jido.Slices.Memory)
    end
  end

  defmodule HostWithoutMemoryOverride do
    @moduledoc false
    use Jido.Agent, default_slices: false

    agent do
      name "host_memory_default"
    end

    slices do
      slice(:memory, Jido.Slices.Memory)
    end
  end

  describe "agent-declared mount path" do
    test "renames the slice's mount path when the agent picks a non-default" do
      instances = AgentInfo.slice_instances(HostWithMemoryOverride)
      memory = Enum.find(instances, &(&1.module == Jido.Slices.Memory))

      assert memory
      assert memory.path == :short_term
    end

    test "uses the path the agent declared in `slices do …`" do
      instances = AgentInfo.slice_instances(HostWithoutMemoryOverride)
      memory = Enum.find(instances, &(&1.module == Jido.Slices.Memory))

      assert memory
      assert memory.path == :memory
    end
  end

  describe "Slice.Instance.new/2 path arg" do
    test "uses the supplied path" do
      instance = SliceInstance.new(Jido.Slices.Memory, :short_term)

      assert instance.path == :short_term
      assert instance.module == Jido.Slices.Memory
    end

    test "strips the legacy :__path_override__ override key from config" do
      instance =
        SliceInstance.new({Jido.Slices.Memory, %{__path_override__: :renamed}}, :memory)

      refute Map.has_key?(instance.config, :__path_override__)
    end
  end
end
