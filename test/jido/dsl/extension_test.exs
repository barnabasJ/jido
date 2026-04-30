defmodule Jido.Dsl.ExtensionTest do
  @moduledoc """
  Unit tests for `Jido.Slice.Extension` and the host-contribution
  schema translator.
  """

  use ExUnit.Case, async: true

  alias Jido.Slice.Extension.SchemaTranslate

  describe "Jido.Slice.Extension.__using__/1" do
    test "exposes the host section name on the slice" do
      assert Jido.Memory.Slice.__jido_host_section__() == :memory
      assert Jido.Identity.Slice.__jido_host_section__() == :identity
      assert Jido.Thread.Slice.__jido_host_section__() == :thread
    end

    test "produces a Spark.Dsl.Section from __jido_host_contribution__/0" do
      section = Jido.Memory.Slice.__jido_host_contribution__()

      assert %Spark.Dsl.Section{name: :memory, schema: schema} = section
      assert is_list(schema)
      # task 0053: path is no longer in the contributed section — it lives
      # on the agent's `slices do slice :path, Module end` mount.
      refute Keyword.has_key?(schema, :path)
    end

    test "creates a sibling Spark.Dsl.Extension shadow module" do
      shadow = Jido.Memory.Slice.__jido_host_extension_module__()

      assert shadow == Jido.Memory.Slice.HostExtension
      assert Code.ensure_loaded?(shadow)
      assert Spark.implements_behaviour?(shadow, Spark.Dsl.Extension)

      [section] = shadow.sections()
      assert section.name == :memory
    end
  end

  describe "SchemaTranslate.translate/1" do
    test "returns [] for nil" do
      assert SchemaTranslate.translate(nil) == []
    end

    test "translates atomic Zoi types" do
      schema =
        Zoi.object(%{
          flag: Zoi.boolean() |> Zoi.default(true),
          count: Zoi.integer() |> Zoi.default(0),
          label: Zoi.string() |> Zoi.optional(),
          mode: Zoi.atom() |> Zoi.default(:idle)
        })

      result = SchemaTranslate.translate(schema)

      assert result[:flag][:type] == :boolean
      assert result[:flag][:default] == true
      assert result[:count][:type] == :integer
      assert result[:count][:default] == 0
      assert result[:label][:type] == :string
      assert result[:mode][:type] == :atom
      assert result[:mode][:default] == :idle
    end

    test "translates Zoi.list to {:list, inner}" do
      schema =
        Zoi.object(%{
          tags: Zoi.list(Zoi.string()) |> Zoi.default([])
        })

      result = SchemaTranslate.translate(schema)
      assert result[:tags][:type] == {:list, :string}
      assert result[:tags][:default] == []
    end

    test "Zoi.list of atoms becomes {:list, :atom}" do
      schema =
        Zoi.object(%{
          tools: Zoi.list(Zoi.atom()) |> Zoi.default([])
        })

      result = SchemaTranslate.translate(schema)
      assert result[:tools][:type] == {:list, :atom}
    end

    test "exotic Zoi shapes fall back to :any" do
      schema =
        Zoi.object(%{
          weird: Zoi.union([Zoi.string(), Zoi.integer()])
        })

      result = SchemaTranslate.translate(schema)
      assert result[:weird][:type] == :any
    end

    test "returns [] for non-object inputs (top-level fallback)" do
      assert SchemaTranslate.translate(Zoi.string()) == []
    end
  end

  describe "DSL section schema validation" do
    test "valid memory block compiles cleanly when extensions: registers the host section" do
      Code.compile_string("""
      defmodule Jido.Dsl.ExtensionTest.HostValidMemory do
        use Jido.Agent,
          extensions: [Jido.Memory.Slice],
          default_slices: false

        agent do
          name "host_valid_memory"
        end

        slices do
          slice :short_term, Jido.Memory.Slice
        end
      end
      """)

      assert Code.ensure_loaded?(Jido.Dsl.ExtensionTest.HostValidMemory)
    end
  end

  describe "section name collisions" do
    defmodule SliceA do
      @moduledoc false
      use Jido.Slice

      slice do
        name "slice_a"
        schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
      end

      signal_routes do
        route "a.noop", JidoTest.PluginTestAction
      end

      use Jido.Slice.Extension, host_section: :colliding
    end

    defmodule SliceB do
      @moduledoc false
      use Jido.Slice

      slice do
        name "slice_b"
        schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
      end

      signal_routes do
        route "b.noop", JidoTest.PluginTestAction
      end

      use Jido.Slice.Extension, host_section: :colliding
    end

    test "raises when two extensions contribute the same section name" do
      slice_a = SliceA
      slice_b = SliceB

      assert_raise Spark.Error.DslError, ~r/Section name collisions/, fn ->
        Code.compile_string("""
        defmodule Jido.Dsl.ExtensionTest.CollidingHost do
          use Jido.Agent,
            extensions: [#{inspect(slice_a)}, #{inspect(slice_b)}],
            default_slices: false

          agent do
            name "colliding_host"
          end

          slices do
            slice :slice_a, #{inspect(slice_a)}
            slice :slice_b, #{inspect(slice_b)}
          end
        end
        """)
      end
    end
  end
end
