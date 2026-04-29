defmodule Jido.Dsl.ActionTest do
  use ExUnit.Case, async: true

  alias Jido.Dsl.Action.Info, as: ActionInfo

  describe "sectioned DSL accessor parity" do
    defmodule MinimalAction do
      @moduledoc false
      use Jido.Action

      action do
        name "minimal"
      end

      def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
    end

    defmodule FullAction do
      @moduledoc false
      use Jido.Action

      action do
        name "full"
        description "Full action with every accessor populated."
        category "test"
        tags ["a", "b"]
        vsn "1.2.3"
        path :counter
        schema by: [type: :integer, default: 1]
        output_schema(count: [type: :integer])
      end

      def run(%Jido.Signal{data: %{by: by}}, slice, _opts, _ctx) do
        slice = slice || %{count: 0}
        {:ok, %{slice | count: slice.count + by}, []}
      end
    end

    test "name/1 returns the configured name" do
      assert ActionInfo.name(FullAction) == "full"
      assert ActionInfo.name(MinimalAction) == "minimal"
    end

    test "description/1, category/1, tags/1, vsn/1 round-trip" do
      assert ActionInfo.description(FullAction) == "Full action with every accessor populated."
      assert ActionInfo.category(FullAction) == "test"
      assert ActionInfo.tags(FullAction) == ["a", "b"]
      assert ActionInfo.vsn(FullAction) == "1.2.3"
    end

    test "tags/1 defaults to []" do
      assert ActionInfo.tags(MinimalAction) == []
    end

    test "schema/1 and output_schema/1 round-trip the configured value" do
      assert ActionInfo.schema(FullAction) == [by: [type: :integer, default: 1]]
      assert ActionInfo.output_schema(FullAction) == [count: [type: :integer]]
    end

    test "schema/1 and output_schema/1 default to []" do
      assert ActionInfo.schema(MinimalAction) == []
      assert ActionInfo.output_schema(MinimalAction) == []
    end

    test "Spark.Dsl.is?(mod, Jido.Action) is true for action modules" do
      assert Spark.Dsl.is?(FullAction, Jido.Action)
    end

    test "to_json/1 returns the same shape as the legacy macro emit" do
      meta = ActionInfo.to_json(FullAction)
      assert meta.name == "full"
      assert meta.description == "Full action with every accessor populated."
      assert meta.category == "test"
      assert meta.tags == ["a", "b"]
      assert meta.vsn == "1.2.3"
      assert meta.path == :counter
      assert meta.schema == [by: [type: :integer, default: 1]]
      assert meta.output_schema == [count: [type: :integer]]
    end
  end

  describe "path defaulting" do
    defmodule PathlessAction do
      @moduledoc false
      use Jido.Action

      action do
        name "pathless"
        schema []
      end

      def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
    end

    test "an action with no path: returns nil from path/1" do
      # Jido.Agent.cmd/2 falls back to the agent's own path: when the
      # action's path/1 is nil. The accessor must return nil so that
      # fallback is reachable.
      assert ActionInfo.path(PathlessAction) == nil
    end
  end

  describe "schema shapes" do
    defmodule ZoiSchemaAction do
      @moduledoc false
      use Jido.Action

      action do
        name "zoi_schema"
        schema(Zoi.object(%{value: Zoi.integer()}))
        output_schema(Zoi.object(%{result: Zoi.integer()}))
      end

      def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
    end

    defmodule NimbleSchemaAction do
      @moduledoc false
      use Jido.Action

      action do
        name "nimble_schema"
        schema value: [type: :integer, default: 0]
      end

      def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
    end

    test "schema/1 exposes a Zoi schema verbatim" do
      schema = ActionInfo.schema(ZoiSchemaAction)
      assert is_struct(schema)
      assert {:ok, %{value: 7}} = Zoi.parse(schema, %{value: 7})
    end

    test "output_schema/1 exposes a Zoi schema verbatim" do
      schema = ActionInfo.output_schema(ZoiSchemaAction)
      assert is_struct(schema)
      assert {:ok, %{result: 5}} = Zoi.parse(schema, %{result: 5})
    end

    test "schema/1 also accepts a NimbleOptions keyword shape" do
      assert ActionInfo.schema(NimbleSchemaAction) == [value: [type: :integer, default: 0]]
    end
  end

  describe "validate_params/1 and validate_output/1" do
    defmodule ValidatedAction do
      @moduledoc false
      use Jido.Action

      action do
        name "validated"
        schema value: [type: :integer, required: true]
        output_schema(result: [type: :string])
      end

      def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
    end

    test "validate_params/1 accepts known params" do
      assert {:ok, %{value: 1}} = ValidatedAction.validate_params(%{value: 1})
    end

    test "validate_output/1 accepts a known output" do
      assert {:ok, %{result: "ok"}} = ValidatedAction.validate_output(%{result: "ok"})
    end
  end

  describe "behaviour" do
    test "modules use Jido.Action implement the @behaviour" do
      defmodule BehaviourCheckAction do
        @moduledoc false
        use Jido.Action

        action do
          name "behaviour_check"
        end

        def run(_signal, slice, _opts, _ctx), do: {:ok, slice, []}
      end

      behaviours =
        BehaviourCheckAction.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Action in behaviours
    end
  end
end
