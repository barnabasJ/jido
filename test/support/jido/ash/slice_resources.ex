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

defmodule JidoTest.Ash.SignalPayloadSliceResource do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: nil,
    extensions: [Jido.Ash.Slice]

  attributes do
    attribute :title, :string,
      allow_nil?: false,
      public?: true,
      description: "Title from payload"

    attribute :attempts, :integer, default: 0, public?: true
  end

  actions do
    action :record do
      argument :reason, :string, allow_nil?: false, description: "Reason for the signal"
      argument :urgent, :boolean, default: false
    end

    update :rename do
      accept [:title, :attempts]
    end
  end

  resource do
    require_primary_key? false
  end

  jido_slice do
    name :payload_event_loop

    signal("event.record", :record)
    signal("event.rename", :rename)
  end
end

defmodule JidoTest.Ash.UnsupportedSignalPayloadSliceResource do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: nil,
    extensions: [Jido.Ash.Slice]

  actions do
    action :record do
      argument :blob, :binary, allow_nil?: false
    end
  end

  resource do
    require_primary_key? false
  end

  jido_slice do
    name :unsupported_payload

    signal("event.record", :record)
  end
end

defmodule JidoTest.Ash.IncrementReducer do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Jido.Ash.Slice.ReducerResult

  @impl Ash.Resource.Actions.Implementation
  @spec run(
          input :: Ash.ActionInput.t(),
          opts :: keyword(),
          context :: Ash.Resource.Actions.Implementation.context()
        ) :: {:ok, ReducerResult.t()}
  def run(input, _opts, _context) do
    slice = Map.get(input.context, :slice, %{})
    amount = input.arguments.amount
    count = Map.get(slice, :count, 0) + amount

    signal =
      Jido.Signal.new!(%{type: "counter.incremented", source: "/test", data: %{count: count}})

    directive = %Jido.Directives.Emit{signal: signal}

    {:ok, ReducerResult.new(Map.put(slice, :count, count), [directive])}
  end
end

defmodule JidoTest.Ash.FailingReducer do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl Ash.Resource.Actions.Implementation
  @spec run(
          input :: Ash.ActionInput.t(),
          opts :: keyword(),
          context :: Ash.Resource.Actions.Implementation.context()
        ) :: {:ok, {:error, {:reducer_failed, String.t()}}}
  def run(input, _opts, _context) do
    {:ok, {:error, {:reducer_failed, input.arguments.reason}}}
  end
end

defmodule JidoTest.Ash.ReducerSliceResource do
  @moduledoc false
  use Ash.Resource,
    domain: JidoTest.Ash.ReducerDomain,
    data_layer: nil,
    extensions: [Jido.Ash.Slice]

  attributes do
    attribute :count, :integer, default: 0, public?: true
  end

  actions do
    action :increment, :term do
      argument :amount, :integer, default: 1

      run JidoTest.Ash.IncrementReducer
    end

    action :fail, :term do
      argument :reason, :string, allow_nil?: false

      run JidoTest.Ash.FailingReducer
    end
  end

  resource do
    require_primary_key? false
  end

  jido_slice do
    name :counter

    signal("counter.increment", :increment)
    signal("counter.fail", :fail)
  end
end

defmodule JidoTest.Ash.ReducerDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource JidoTest.Ash.ReducerSliceResource
  end
end
