defmodule Jido.Dsl.ExtensionComposeTest do
  @moduledoc """
  Tests that multiple contributed sections compose cleanly on a single
  host agent (each slice's `<host_section> do … end` block applies
  independently).
  """

  use ExUnit.Case, async: true

  alias Jido.Dsl.Agent.Info, as: AgentInfo

  # Path overrides now live in the agent's `slices do …` block, not in
  # contributed-section `path:` fields. The contributed sections still
  # carry per-slice config (when the slice has a `config_schema/0`); they
  # just don't carry path anymore.
  defmodule MultiHost do
    @moduledoc false
    use Jido.Agent, default_slices: false

    agent do
      name "multi_host"
    end

    slices do
      slice(:short_term, Jido.Slices.Memory)
      slice(:who, Jido.Slices.Identity)
      slice(:history, Jido.Slices.Thread)
    end
  end

  describe "multiple contributions compose" do
    test "all three slices mount at the agent-declared paths" do
      instances = AgentInfo.slice_instances(MultiHost)

      memory = Enum.find(instances, &(&1.module == Jido.Slices.Memory))
      identity = Enum.find(instances, &(&1.module == Jido.Slices.Identity))
      thread = Enum.find(instances, &(&1.module == Jido.Slices.Thread))

      assert memory.path == :short_term
      assert identity.path == :who
      assert thread.path == :history
    end
  end

  defmodule HostNoBlocks do
    @moduledoc false
    use Jido.Agent, default_slices: false

    agent do
      name "host_no_blocks"
    end

    slices do
      slice(:memory, Jido.Slices.Memory)
      slice(:identity, Jido.Slices.Identity)
    end
  end

  describe "extensions without contribution blocks" do
    test "still produce slice instances at the slice's declared path" do
      instances = AgentInfo.slice_instances(HostNoBlocks)

      memory = Enum.find(instances, &(&1.module == Jido.Slices.Memory))
      identity = Enum.find(instances, &(&1.module == Jido.Slices.Identity))

      assert memory.path == :memory
      assert identity.path == :identity
    end
  end
end
