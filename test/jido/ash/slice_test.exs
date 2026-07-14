defmodule Jido.Ash.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Ash.Slice.Info
  alias Jido.Ash.Slice.SignalEntry

  defmodule DeclaredSliceResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: nil,
      extensions: [Jido.Ash.Slice]

    actions do
      action :start
      action :cancel
    end

    jido_slice do
      name :event_loop
      description "Event loop slice"
      category "reasoning"
      vsn "0.1.0"
      otp_app :jido
      tags ["agent", "reasoning"]

      signal("event.start", :start)
      signal("event.cancel", :cancel)
    end
  end

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
end
