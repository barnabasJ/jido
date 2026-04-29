defmodule Jido.Dsl.ExtensionReactTest do
  @moduledoc """
  End-to-end test for `Jido.AI.ReAct` contributing a `react do … end`
  block to a host agent. Covers:

    * single-extension contribution (the basic case)
    * `extensions: [{ReAct, as: :slice}]` mounts ReAct slice-only
      (i.e. the same surface as the no-`react`-block fallback)
    * the contributed config flows into the slice's resolved config

  Mimic stubs out `ReqLLM.Generation.generate_text/3` since the slice
  config carries a model spec we need to keep deterministic in tests.
  """

  use ExUnit.Case, async: true

  alias Jido.AI.ReAct
  alias Jido.Dsl.Agent.Info, as: AgentInfo

  defmodule SupportAgent do
    @moduledoc false
    use Jido.Agent, extensions: [Jido.AI.ReAct], default_slices: false

    agent do
      name "support"
    end

    react do
      model("anthropic:claude-haiku-4-5-20251001")
      tools([Jido.AI.TestActions.TestAdd])
      system_prompt("You are a support agent.")
      max_iterations(5)
    end
  end

  describe "single contribution: ReAct + react do … end" do
    test "produces a slice instance for ReAct mounted at :ai" do
      instances = AgentInfo.slice_instances(SupportAgent)
      react_instance = Enum.find(instances, &(&1.module == ReAct))

      assert react_instance
      assert react_instance.path == :ai
    end

    test "applies the typed-block config to the slice instance" do
      instances = AgentInfo.slice_instances(SupportAgent)
      %{config: config} = Enum.find(instances, &(&1.module == ReAct))

      assert config[:model] == "anthropic:claude-haiku-4-5-20251001"
      assert config[:tools] == [Jido.AI.TestActions.TestAdd]
      assert config[:system_prompt] == "You are a support agent."
      assert config[:max_iterations] == 5
    end
  end

  defmodule SliceOnlyAgent do
    @moduledoc false
    use Jido.Agent,
      extensions: [{Jido.AI.ReAct, as: :slice}],
      default_slices: false

    agent do
      name "slice_only"
    end
  end

  describe "override form: {ReAct, as: :slice}" do
    test "still produces a slice instance for ReAct" do
      instances = AgentInfo.slice_instances(SliceOnlyAgent)
      react_instance = Enum.find(instances, &(&1.module == ReAct))

      assert react_instance
      assert react_instance.path == :ai
    end
  end

  defmodule RenamedReactAgent do
    @moduledoc false
    use Jido.Agent, extensions: [Jido.AI.ReAct], default_slices: false

    agent do
      name "renamed_react"
    end

    react do
      path :reasoning
      model("anthropic:claude-haiku-4-5-20251001")
      tools([Jido.AI.TestActions.TestAdd])
    end
  end

  describe "path override on the contributed react section" do
    test "renames the slice's mount path" do
      instances = AgentInfo.slice_instances(RenamedReactAgent)
      react_instance = Enum.find(instances, &(&1.module == ReAct))

      assert react_instance.path == :reasoning
    end
  end
end
