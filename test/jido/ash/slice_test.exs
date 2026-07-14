defmodule Jido.Ash.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Ash.Slice.Info
  alias Jido.Ash.Slice.SignalEntry
  alias Jido.Ash.Slice.StateField
  alias JidoTest.Ash.DeclaredSliceResource
  alias JidoTest.Ash.StateSliceResource
  alias JidoTest.Ash.UnsupportedStateSliceResource

  @tag story: "US-AJSL-01"
  test "an Ash resource can declare a Jido slice block and signal bindings" do
    # Given an Ash resource using the Jido Ash slice extension
    # When the module declares slice metadata and signal bindings
    # Then the resource compiles and exposes the declaration for later generation
    assert Spark.Dsl.is?(DeclaredSliceResource, Ash.Resource)
    assert Info.name(DeclaredSliceResource) == "event_loop"

    assert [
             %SignalEntry{type: "event.start", action: :start},
             %SignalEntry{type: "event.cancel", action: :cancel}
           ] = Info.signals(DeclaredSliceResource)
  end

  @tag story: "US-AJSL-05"
  test "Info exposes metadata and generation placeholders" do
    # Given an Ash-backed slice resource with metadata and signal bindings
    # When a developer calls the Info accessors
    # Then they receive stable declaration data and empty generation placeholders
    assert Info.description(DeclaredSliceResource) == "Event loop slice"
    assert Info.category(DeclaredSliceResource) == "reasoning"
    assert Info.vsn(DeclaredSliceResource) == "0.1.0"
    assert Info.otp_app(DeclaredSliceResource) == :jido
    assert Info.tags(DeclaredSliceResource) == ["agent", "reasoning"]

    assert [
             %SignalEntry{type: "event.start", action: :start},
             %SignalEntry{type: "event.cancel", action: :cancel}
           ] = Info.signals(DeclaredSliceResource)

    assert Info.generated_slice_module(DeclaredSliceResource) == nil
    assert Info.generated_action_modules(DeclaredSliceResource) == []
  end

  @tag story: "US-AJSL-07"
  test "Info derives a slice state schema from Ash attributes" do
    # Given an Ash-backed slice resource with typed attributes
    # When a developer asks for state fields and the derived state schema
    # Then attributes, defaults, docs, and public metadata are represented
    assert [
             %StateField{
               name: :title,
               type: Ash.Type.String,
               allow_nil?: false,
               public?: true,
               default: :none,
               description: "Visible title"
             },
             %StateField{name: :attempts, type: Ash.Type.Integer, default: {:static, 0}},
             %StateField{name: :active, type: Ash.Type.Boolean, default: {:static, true}},
             %StateField{name: :tags, type: {:array, Ash.Type.String}, default: {:static, []}},
             %StateField{name: :metadata, type: Ash.Type.Map, allow_nil?: true, public?: false}
           ] = Info.state_fields(StateSliceResource)

    schema = Info.state_schema(StateSliceResource)

    assert {:ok, %{title: "run", attempts: 0, active: true, tags: []}} =
             Zoi.parse(schema, %{title: "run"})

    assert {:ok, %{title: "run", metadata: nil, attempts: 0, active: true, tags: []}} =
             Zoi.parse(schema, %{title: "run", metadata: nil})

    assert {:error, [%Zoi.Error{code: :required, path: [:title]}]} = Zoi.parse(schema, %{})
  end

  @tag story: "US-AJSL-08"
  test "unsupported Ash attribute types fail clearly" do
    # Given an Ash-backed slice resource with an unsupported state type
    # When a developer asks for the derived state schema
    # Then the error names the unsupported Ash type instead of silently using any
    assert_raise ArgumentError,
                 ~r/unsupported Ash-backed slice state attribute type Ash.Type.Binary/,
                 fn ->
                   Info.state_schema(UnsupportedStateSliceResource)
                 end
  end
end
