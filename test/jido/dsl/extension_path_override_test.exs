defmodule Jido.Dsl.ExtensionPathOverrideTest do
  @moduledoc """
  Pre-wires the read-side of the per-extension `path:` override that the
  contribution mechanism (task 0041) will plug into. Today no slice exports
  `__jido_host_section__/0`, so this contract is exercised against
  hand-built `dsl_state` maps and a stub slice that simulates what task
  0041's `Jido.Slice.Extension` will inject.

  The full user-facing test (`memory do path :short_term end` against a
  real agent) is deferred to task 0041 — it cannot run until the macro
  exists.
  """

  use ExUnit.Case, async: true

  alias Jido.Dsl.Agent.Transformers.WalkExtensions
  alias Jido.Slice.Instance, as: SliceInstance

  defmodule StubContributingSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "stub_contributing"
      path :stub
      description "Pretends to contribute a host DSL section."
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "stub_contributing.noop", JidoTest.PluginTestAction
    end

    @doc """
    Mirrors what `Jido.Slice.Extension` (task 0041) is expected to inject
    on every contributed slice. Returns the section name the host can
    write to.
    """
    def __jido_host_section__, do: :stub
  end

  defmodule StubNonContributingSlice do
    @moduledoc false
    use Jido.Slice

    slice do
      name "stub_non_contributing"
      path :stub_no_section
      description "Does not contribute a host DSL section."
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "stub_non_contributing.noop", JidoTest.PluginTestAction
    end
  end

  describe "apply_section_path_override/2" do
    setup do
      instance = SliceInstance.new(StubContributingSlice)
      %{instance: instance}
    end

    test "returns the instance unchanged when the slice has no contributed section",
         %{instance: _stub_instance} do
      non_contrib = SliceInstance.new(StubNonContributingSlice)
      result = WalkExtensions.apply_section_path_override(non_contrib, %{})
      assert result.path == :stub_no_section
    end

    test "returns the instance unchanged when the host has not set :path on the section",
         %{instance: instance} do
      dsl_state = %{[:stub] => %{opts: []}}
      result = WalkExtensions.apply_section_path_override(instance, dsl_state)
      assert result.path == :stub
    end

    test "returns the instance unchanged when the section is absent from dsl_state",
         %{instance: instance} do
      result = WalkExtensions.apply_section_path_override(instance, %{})
      assert result.path == :stub
    end

    test "applies the host-set :path override when present in the contributed section",
         %{instance: instance} do
      dsl_state = %{[:stub] => %{opts: [path: :short_term]}}
      result = WalkExtensions.apply_section_path_override(instance, dsl_state)
      assert result.path == :short_term
    end

    test "preserves all other instance fields when overriding the path",
         %{instance: instance} do
      dsl_state = %{[:stub] => %{opts: [path: :renamed]}}
      result = WalkExtensions.apply_section_path_override(instance, dsl_state)

      assert result.module == instance.module
      assert result.config == instance.config
      assert result.as == instance.as
    end
  end
end
