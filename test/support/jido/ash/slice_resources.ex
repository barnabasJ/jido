defmodule JidoTest.Ash.DeclaredSliceResource do
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

defmodule JidoTest.Ash.StateSliceResource do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: nil,
    extensions: [Jido.Ash.Slice]

  attributes do
    attribute :title, :string,
      allow_nil?: false,
      public?: true,
      description: "Visible title"

    attribute :attempts, :integer, default: 0, public?: true
    attribute :active, :boolean, default: true, public?: true
    attribute :tags, {:array, :string}, default: [], public?: true
    attribute :metadata, :map, public?: false
  end

  resource do
    require_primary_key? false
  end

  jido_slice do
    name :stateful_event_loop
  end
end

defmodule JidoTest.Ash.UnsupportedStateSliceResource do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: nil,
    extensions: [Jido.Ash.Slice]

  attributes do
    attribute :blob, :binary, public?: true
  end

  resource do
    require_primary_key? false
  end

  jido_slice do
    name :unsupported_state
  end
end
