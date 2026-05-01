defmodule Jido.Dsl.ExtensionTest do
  @moduledoc """
  Unit tests for `Jido.Slice.Extension.build_section/2` /
  `Jido.Slice.Extension.SchemaTranslate.translate/1`, plus an end-to-end
  check that a host agent listing a contributing slice in `extensions:` and
  mounting it in `slices do …` compiles cleanly.

  Section-name collision detection lives in
  `Jido.Dsl.Agent.Verifiers.NoSectionNameCollisionsTest`.
  """

  use ExUnit.Case, async: true

  alias Jido.Slice.Extension.SchemaTranslate

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
end
