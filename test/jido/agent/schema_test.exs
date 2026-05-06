defmodule JidoTest.Agent.SchemaTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Schema

  describe "merge_with_plugins/2" do
    test "nil base with no plugins returns nil" do
      assert Schema.merge_with_plugins(nil, []) == nil
    end

    test "base schema with no plugins returns base" do
      base = Zoi.object(%{mode: Zoi.atom()})
      result = Schema.merge_with_plugins(base, [])
      assert result == base
    end

    test "nil base with slices returns slice fields only" do
      slice_spec = %{path: :my_slice, schema: Zoi.object(%{count: Zoi.integer()})}

      result = Schema.merge_with_plugins(nil, [slice_spec])

      assert result != nil
      keys = Schema.known_keys(result)
      assert :my_slice in keys
    end

    test "base with slices merges both" do
      base = Zoi.object(%{mode: Zoi.atom()})
      slice_spec = %{path: :slice_data, schema: Zoi.object(%{value: Zoi.integer()})}

      result = Schema.merge_with_plugins(base, [slice_spec])

      keys = Schema.known_keys(result)
      assert :mode in keys
      assert :slice_data in keys
    end

    test "filters out slices without schema" do
      slice_with_schema = %{path: :slice_a, schema: Zoi.object(%{a: Zoi.integer()})}
      slice_without_schema = %{path: :slice_b, schema: nil}

      result = Schema.merge_with_plugins(nil, [slice_with_schema, slice_without_schema])

      keys = Schema.known_keys(result)
      assert :slice_a in keys
      refute :slice_b in keys
    end
  end

  describe "known_keys/1" do
    test "returns empty list for nil" do
      assert Schema.known_keys(nil) == []
    end

    test "returns keys from Zoi object with map fields" do
      schema = Zoi.object(%{status: Zoi.atom(), count: Zoi.integer()})
      keys = Schema.known_keys(schema)
      assert :status in keys
      assert :count in keys
    end

    test "returns keys from Zoi Map type with map fields" do
      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()})
      keys = Schema.known_keys(schema)
      assert :name in keys
      assert :age in keys
    end

    test "returns keys from Zoi Struct type with map fields" do
      schema =
        Zoi.struct(
          JidoTest.Agent.SchemaTest.TestStruct,
          %{field_a: Zoi.string(), field_b: Zoi.integer()}
        )

      keys = Schema.known_keys(schema)
      assert :field_a in keys
      assert :field_b in keys
    end

    test "returns empty list for unknown schema type" do
      assert Schema.known_keys("not a schema") == []
      assert Schema.known_keys(123) == []
    end
  end

  describe "defaults_from_zoi_schema/1" do
    test "returns empty map for nil" do
      assert Schema.defaults_from_zoi_schema(nil) == %{}
    end

    test "extracts defaults from Zoi object" do
      schema =
        Zoi.object(%{
          status: Zoi.atom() |> Zoi.default(:idle),
          count: Zoi.integer()
        })

      defaults = Schema.defaults_from_zoi_schema(schema)
      assert defaults == %{status: :idle}
    end

    test "handles multiple defaults" do
      schema =
        Zoi.object(%{
          status: Zoi.atom() |> Zoi.default(:idle),
          count: Zoi.integer() |> Zoi.default(0),
          name: Zoi.string()
        })

      defaults = Schema.defaults_from_zoi_schema(schema)
      assert defaults == %{status: :idle, count: 0}
    end

    test "returns empty map when no defaults" do
      schema =
        Zoi.object(%{
          status: Zoi.atom(),
          count: Zoi.integer()
        })

      defaults = Schema.defaults_from_zoi_schema(schema)
      assert defaults == %{}
    end

    test "extracts defaults from Zoi Map type" do
      schema =
        Zoi.map(%{
          name: Zoi.string() |> Zoi.default("unknown"),
          count: Zoi.integer()
        })

      defaults = Schema.defaults_from_zoi_schema(schema)
      assert defaults == %{name: "unknown"}
    end

    test "extracts defaults from Zoi Struct type" do
      schema =
        Zoi.struct(
          JidoTest.Agent.SchemaTest.TestStruct,
          %{
            field_a: Zoi.string() |> Zoi.default("default_a"),
            field_b: Zoi.integer()
          }
        )

      defaults = Schema.defaults_from_zoi_schema(schema)
      assert defaults == %{field_a: "default_a"}
    end

    test "returns empty map for unknown schema type" do
      assert Schema.defaults_from_zoi_schema("not a schema") == %{}
    end
  end
end
