defmodule Jido.Dsl.Agent.Transformers.WalkExtensionsSectionCollisionTest do
  @moduledoc """
  Compile-time regression: section-name collisions across the
  `:jido_contributed_sections` map are caught at the start of
  `Jido.Dsl.Agent.Transformers.WalkExtensions`, regardless of whether
  each contributing extension is Pod-style (own bespoke
  RegisterContribution transformer file) or follows any other shape.

  Closes the gap left by [task 0061](../../../../../guides/tasks/0061-collapse-pod-into-agent-extension.md):
  the deleted `Jido.Dsl.Agent.Transformers.DiscoverExtensions` only saw
  legacy slice extensions, missing Pod entirely. The check now reads the
  final `:jido_contributed_sections` map populated by every contributor's
  RegisterContribution transformer (which run `before?(WalkExtensions)`).
  """

  use ExUnit.Case, async: true

  test "raises when Jido.Slices.Pod is mounted alongside a slice that also picks `:pod`" do
    assert_raise Spark.Error.DslError, ~r/Section name collisions.*:pod/s, fn ->
      Code.compile_string("""
      defmodule Jido.Dsl.Agent.Transformers.WalkExtensionsSectionCollisionTest.PodCollidingHost do
        use Jido.Agent,
          extensions: [Jido.Slices.Pod, JidoTest.Fixtures.CollidingPodExtension],
          default_slices: false

        agent do
          name "pod_colliding_host"
        end

        slices do
          slice :pod, Jido.Slices.Pod
          slice :other_pod, JidoTest.Fixtures.CollidingPodExtension
        end
      end
      """)
    end
  end

  test "mounting just Jido.Slices.Pod compiles cleanly" do
    Code.compile_string("""
    defmodule Jido.Dsl.Agent.Transformers.WalkExtensionsSectionCollisionTest.PodAloneHost do
      use Jido.Agent,
        extensions: [Jido.Slices.Pod],
        default_slices: false

      agent do
        name "pod_alone_host"
      end

      slices do
        slice :pod, Jido.Slices.Pod
      end
    end
    """)

    assert Code.ensure_loaded?(
             Jido.Dsl.Agent.Transformers.WalkExtensionsSectionCollisionTest.PodAloneHost
           )
  end
end
