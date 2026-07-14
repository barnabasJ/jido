defmodule Jido.Ash.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Ash.Slice.PayloadField
  alias Jido.Ash.Slice.Info
  alias Jido.Ash.Slice.SignalEntry
  alias Jido.Ash.Slice.SignalPayload
  alias Jido.Ash.Slice.StateField
  alias Jido.Ash.Slice.Verifiers.SignalActionsExist
  alias JidoTest.Ash.DeclaredSliceResource
  alias JidoTest.Ash.SignalPayloadSliceResource
  alias JidoTest.Ash.StateSliceResource
  alias JidoTest.Ash.UnsupportedSignalPayloadSliceResource
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

  @tag story: "US-AJSL-09"
  test "Info derives signal payload schemas from Ash action inputs" do
    # Given an Ash-backed slice with signal bindings to an action and an update
    # When a developer inspects signal payloads and schemas
    # Then action arguments and accepted attributes appear in stable payload shape
    assert [
             %SignalPayload{
               type: "event.record",
               action: :record,
               fields: [
                 %PayloadField{name: :reason, source: :argument, allow_nil?: false},
                 %PayloadField{name: :urgent, source: :argument, default: {:static, false}}
               ]
             },
             %SignalPayload{
               type: "event.rename",
               action: :rename,
               fields: [
                 %PayloadField{name: :title, source: :attribute, allow_nil?: false},
                 %PayloadField{name: :attempts, source: :attribute, default: {:static, 0}}
               ]
             }
           ] = Info.signal_payloads(SignalPayloadSliceResource)

    record_schema = Info.signal_payload_schema(SignalPayloadSliceResource, "event.record")

    assert {:ok, %{reason: "because", urgent: false}} =
             Zoi.parse(record_schema, %{reason: "because"})

    assert {:error, [%Zoi.Error{code: :required, path: [:reason]}]} =
             Zoi.parse(record_schema, %{})

    rename_schema = Info.signal_payload_schema(SignalPayloadSliceResource, "event.rename")
    assert {:ok, %{title: "next", attempts: 0}} = Zoi.parse(rename_schema, %{title: "next"})

    assert_raise ArgumentError,
                 ~r/unsupported Ash-backed slice payload field type Ash.Type.Binary/,
                 fn ->
                   Info.signal_payload_schema(
                     UnsupportedSignalPayloadSliceResource,
                     "event.record"
                   )
                 end
  end

  @tag story: "US-AJSL-10"
  test "missing signal target actions fail at compile time" do
    # Given an Ash-backed slice signal that references a missing action
    # When the verifier checks the resource's signal declarations
    # Then the verifier reports the missing target action clearly
    dsl_state = %{
      [:jido_slice] => %{entities: [%SignalEntry{type: "event.missing", action: :missing}]},
      persist: %{module: DeclaredSliceResource}
    }

    assert {:error,
            %Spark.Error.DslError{
              message:
                "jido_slice signal \"event.missing\" references missing Ash action :missing",
              path: [:jido_slice, :signal]
            }} = SignalActionsExist.verify(dsl_state)
  end
end
