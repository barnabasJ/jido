defmodule JidoExampleTest.EmitDirectiveTest do
  @moduledoc """
  Example test demonstrating the Emit directive for domain events.

  This test shows:
  - How actions emit signals via Directive.Emit
  - How to configure dispatch targets (pid, pubsub, etc.)
  - Event-driven patterns where agents produce domain events
  - Combining state updates with signal emission

  Run with: mix test --include example
  """
  use JidoTest.Case, async: false

  @moduletag :example
  @moduletag timeout: 15_000

  alias Jido.Agent.Directive
  alias Jido.AgentServer
  alias Jido.Signal
  alias JidoTest.SignalCollector

  # ===========================================================================
  # ACTIONS: Emit domain events
  # ===========================================================================

  defmodule CreateOrderAction do
    @moduledoc false
    use Jido.Action,
      name: "create_order",
      schema: [
        order_id: [type: :string, required: true],
        items: [type: {:list, :map}, default: []],
        total: [type: :integer, required: true]
      ]

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      orders = Map.get(slice, :orders, [])

      order = %{
        id: params.order_id,
        items: params.items,
        total: params.total,
        status: :pending,
        created_at: DateTime.utc_now()
      }

      event_signal =
        Signal.new!(
          "order.created",
          %{order_id: order.id, total: order.total},
          source: "/order-agent"
        )

      {:ok, %{orders: [order | orders], last_order_id: order.id},
       [%Directive.Emit{signal: event_signal}]}
    end
  end

  defmodule ProcessPaymentAction do
    @moduledoc false
    use Jido.Action,
      name: "process_payment",
      schema: [
        order_id: [type: :string, required: true],
        payment_method: [type: :string, default: "card"]
      ]

    def run(%Jido.Signal{data: params}, _slice, _opts, _ctx) do
      order_id = params.order_id

      payment_signal =
        Signal.new!(
          "payment.processed",
          %{order_id: order_id, method: params.payment_method, status: :success},
          source: "/payment-agent"
        )

      {:ok, %{last_payment: %{order_id: order_id, status: :success}},
       [%Directive.Emit{signal: payment_signal}]}
    end
  end

  defmodule MultiEmitAction do
    @moduledoc false
    use Jido.Action,
      name: "multi_emit",
      schema: [
        event_count: [type: :integer, default: 3]
      ]

    def run(%Jido.Signal{data: %{event_count: count}}, _slice, _opts, _ctx) do
      emissions =
        for i <- 1..count do
          signal = Signal.new!("batch.event", %{index: i}, source: "/batch")
          %Directive.Emit{signal: signal}
        end

      {:ok, %{emitted_count: count}, emissions}
    end
  end

  # ===========================================================================
  # AGENT: Order processing with event emission
  # ===========================================================================

  defmodule OrderAgent do
    @moduledoc false
    use Jido.Agent,
      name: "order_agent",
      path: :domain,
      schema: [
        orders: [type: {:list, :map}, default: []],
        last_order_id: [type: :string, default: nil],
        last_payment: [type: :map, default: nil],
        emitted_count: [type: :integer, default: 0]
      ]

    def signal_routes(_ctx) do
      [
        {"create_order", CreateOrderAction},
        {"process_payment", ProcessPaymentAction},
        {"multi_emit", MultiEmitAction}
      ]
    end
  end

  defmodule InternalIncrementAction do
    @moduledoc false
    use Jido.Action,
      name: "internal_increment",
      schema: [
        amount: [type: :integer, default: 1]
      ]

    def run(%Jido.Signal{data: %{amount: amount}}, slice, _opts, _ctx) do
      current = Map.get(slice, :count, 0)
      new_count = current + amount

      internal_signal =
        Signal.new!(
          "print.count",
          %{previous_count: current, count: new_count},
          source: "/internal-counter"
        )

      {:ok, %{count: new_count}, [Directive.emit(internal_signal)]}
    end
  end

  defmodule InternalPrintCountAction do
    @moduledoc false
    use Jido.Action,
      name: "internal_print_count",
      schema: [
        previous_count: [type: :integer, required: true],
        count: [type: :integer, required: true]
      ]

    def run(
          %Jido.Signal{data: %{previous_count: previous_count, count: count}},
          slice,
          _opts,
          _ctx
        ) do
      if is_pid(slice.observer),
        do: send(slice.observer, {:print_count, previous_count, count})

      {:ok, %{last_seen_count: count}, []}
    end
  end

  defmodule InternalEmitAgent do
    @moduledoc false
    use Jido.Agent,
      name: "internal_emit_agent",
      path: :domain,
      schema: [
        count: [type: :integer, default: 0],
        observer: [type: :any, default: nil],
        last_seen_count: [type: :integer, default: 0]
      ]

    def signal_routes(_ctx) do
      [
        {"count.increment", InternalIncrementAction},
        {"print.count", InternalPrintCountAction}
      ]
    end
  end

  # ===========================================================================
  # TESTS
  # ===========================================================================

  describe "Emit directive basics" do
    test "action can emit a signal as a directive", %{jido: jido} do
      {:ok, collector} = SignalCollector.start_link()

      on_exit(fn ->
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      {:ok, pid} =
        Jido.start_agent(jido, OrderAgent,
          id: unique_id("order"),
          default_dispatch: {:pid, target: collector}
        )

      signal =
        Signal.new!(
          "create_order",
          %{order_id: "ORD-001", items: [%{sku: "WIDGET", qty: 2}], total: 5000},
          source: "/test"
        )

      {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert agent.state.domain.last_order_id == "ORD-001"
      assert length(agent.state.domain.orders) == 1

      eventually(
        fn ->
          signals = SignalCollector.get_signals(collector)
          signals != []
        end,
        timeout: 2_000
      )

      signals = SignalCollector.get_signals(collector)
      [emitted] = signals

      assert emitted.type == "order.created"
      assert emitted.data.order_id == "ORD-001"
      assert emitted.data.total == 5000
    end

    test "state update and emit happen together", %{jido: jido} do
      {:ok, collector} = SignalCollector.start_link()

      on_exit(fn ->
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      {:ok, pid} =
        Jido.start_agent(jido, OrderAgent,
          id: unique_id("order"),
          default_dispatch: {:pid, target: collector}
        )

      {:ok, _} =
        AgentServer.call(
          pid,
          Signal.new!(
            "create_order",
            %{order_id: "ORD-100", total: 1000},
            source: "/test"
          ),
          fn s -> {:ok, s.agent} end
        )

      {:ok, _} =
        AgentServer.call(
          pid,
          Signal.new!(
            "process_payment",
            %{order_id: "ORD-100", payment_method: "paypal"},
            source: "/test"
          ),
          fn s -> {:ok, s.agent} end
        )

      {:ok, %{last_order_id: last_order_id, payment_status: payment_status}} =
        AgentServer.state(pid, fn s ->
          {:ok,
           %{
             last_order_id: s.agent.state.domain.last_order_id,
             payment_status: s.agent.state.domain.last_payment.status
           }}
        end)

      assert last_order_id == "ORD-100"
      assert payment_status == :success

      eventually(
        fn ->
          signals = SignalCollector.get_signals(collector)
          length(signals) >= 2
        end,
        timeout: 2_000
      )

      signals = SignalCollector.get_signals(collector)
      types = Enum.map(signals, & &1.type)

      assert "order.created" in types
      assert "payment.processed" in types
    end
  end

  describe "multiple emissions" do
    test "action can emit multiple signals", %{jido: jido} do
      {:ok, collector} = SignalCollector.start_link()

      on_exit(fn ->
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      {:ok, pid} =
        Jido.start_agent(jido, OrderAgent,
          id: unique_id("order"),
          default_dispatch: {:pid, target: collector}
        )

      signal = Signal.new!("multi_emit", %{event_count: 5}, source: "/test")
      {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert agent.state.domain.emitted_count == 5

      eventually(
        fn ->
          signals = SignalCollector.get_signals(collector)
          length(signals) >= 5
        end,
        timeout: 2_000
      )

      signals = SignalCollector.get_signals(collector)
      assert length(signals) == 5

      indexes = Enum.map(signals, & &1.data.index) |> Enum.sort()
      assert indexes == [1, 2, 3, 4, 5]
    end
  end

  describe "emit loopback" do
    test "emit without dispatch loops back to the current agent", %{jido: jido} do
      {:ok, pid} =
        Jido.start_agent(jido, InternalEmitAgent,
          id: unique_id("internal-emit"),
          initial_state: %{observer: self()}
        )

      signal = Signal.new!("count.increment", %{amount: 1}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert_receive {:print_count, 0, 1}, 2_000
    end
  end
end
