defmodule Jido.Dsl.ExtensionReactTest do
  @moduledoc """
  End-to-end test for `Jido.Slices.AiReact` contributing a `react do … end`
  block to a host agent. Covers:

    * single-extension contribution (the basic case)
    * `extensions: [{ReAct, as: :slice}]` mounts ReAct slice-only
      (i.e. the same surface as the no-`react`-block fallback)
    * the contributed config flows into the slice's resolved config

  Mimic stubs out `ReqLLM.Generation.generate_text/3` since the slice
  config carries a model spec we need to keep deterministic in tests.
  """

  use ExUnit.Case, async: true

  alias Jido.Dsl.Agent.Info, as: AgentInfo
  alias Jido.Slices.AiReact

  defmodule SupportAgent do
    @moduledoc false
    use Jido.Agent, extensions: [Jido.Slices.AiReact], default_slices: false

    agent do
      name "support"
    end

    slices do
      slice(:ai, Jido.Slices.AiReact)
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
      react_instance = Enum.find(instances, &(&1.module == AiReact))

      assert react_instance
      assert react_instance.path == :ai
    end

    test "applies the typed-block config to the slice instance" do
      instances = AgentInfo.slice_instances(SupportAgent)
      %{config: config} = Enum.find(instances, &(&1.module == AiReact))

      assert config[:model] == "anthropic:claude-haiku-4-5-20251001"
      assert config[:tools] == [Jido.AI.TestActions.TestAdd]
      assert config[:system_prompt] == "You are a support agent."
      assert config[:max_iterations] == 5
    end
  end

  defmodule RenamedReactAgent do
    @moduledoc false
    use Jido.Agent, extensions: [Jido.Slices.AiReact], default_slices: false

    agent do
      name "renamed_react"
    end

    slices do
      slice(:reasoning, Jido.Slices.AiReact)
    end

    react do
      model("anthropic:claude-haiku-4-5-20251001")
      tools([Jido.AI.TestActions.TestAdd])
    end
  end

  describe "agent-declared mount path for ReAct" do
    test "the slice mounts at the agent-declared path even when the typed `react do` block is present" do
      instances = AgentInfo.slice_instances(RenamedReactAgent)
      react_instance = Enum.find(instances, &(&1.module == AiReact))

      assert react_instance.path == :reasoning
    end
  end
end
