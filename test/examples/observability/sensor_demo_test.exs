defmodule JidoExampleTest.SensorDemoTest do
  @moduledoc """
  Example test demonstrating Jido Sensors and signal routing.

  This test converts examples/sensor_demo.exs into a proper ExUnit test that:
  - Verifies sensor signals are routed through signal_routes/1
  - Verifies webhook injection works correctly
  - Asserts actual state changes (not just "runs without crash")

  Run with: mix test --include example
  """
  use JidoTest.Case, async: false

  @moduletag :example
  @moduletag timeout: 30_000

  alias Jido.AgentServer
  alias Jido.Signal

  # ===========================================================================
  # ACTIONS: Handle sensor and webhook signals
  # ===========================================================================

  defmodule HandleQuoteAction do
    @moduledoc false

    use Jido.Action,
      name: "handle_quote",
      schema: [
        quote: [type: :string, required: true],
        category: [type: :string, default: "general"],
        emit_count: [type: :integer, default: 0],
        sensor_id: [type: :string, default: "unknown"]
      ]

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      current_quotes = Map.get(slice, :quotes, [])

      quotes = [
        %{
          quote: params.quote,
          category: params.category,
          emit_count: params.emit_count,
          sensor_id: params.sensor_id,
          received_at: DateTime.utc_now()
        }
        | current_quotes
      ]

      {:ok, %{quotes: quotes}, []}
    end
  end

  defmodule HandleGitHubWebhookAction do
    @moduledoc false

    use Jido.Action,
      name: "handle_github_webhook",
      schema: [
        event: [type: :string, required: true],
        payload: [type: :map, default: %{}],
        received_at: [type: :any, required: false]
      ]

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      current_events = Map.get(slice, :events, [])

      events = [
        %{
          source: :github,
          event: params.event,
          payload: params.payload,
          received_at: params[:received_at] || DateTime.utc_now()
        }
        | current_events
      ]

      {:ok, %{events: events}, []}
    end
  end

  defmodule HandleStripeWebhookAction do
    @moduledoc false

    use Jido.Action,
      name: "handle_stripe_webhook",
      schema: [
        event: [type: :string, required: true],
        payload: [type: :map, default: %{}],
        received_at: [type: :any, required: false]
      ]

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      current_events = Map.get(slice, :events, [])

      events = [
        %{
          source: :stripe,
          event: params.event,
          payload: params.payload,
          received_at: params[:received_at] || DateTime.utc_now()
        }
        | current_events
      ]

      {:ok, %{events: events}, []}
    end
  end

  # ===========================================================================
  # AGENT: Collects quotes and events via signal_routes
  # ===========================================================================

  defmodule QuoteCollectorAgent do
    @moduledoc false

    use Jido.Agent,
      name: "quote_collector",
      path: :domain,
      schema: [
        quotes: [type: {:list, :map}, default: []],
        events: [type: {:list, :map}, default: []],
        status: [type: :atom, default: :idle]
      ]

    def signal_routes(_ctx) do
      [
        {"sensor.quote", HandleQuoteAction},
        {"webhook.github", HandleGitHubWebhookAction},
        {"webhook.stripe", HandleStripeWebhookAction}
      ]
    end
  end

  # ===========================================================================
  # SENSOR: Bounded sensor for testing (stops after max_emits)
  # ===========================================================================

  defmodule RandomQuoteSensor do
    @moduledoc false
    use GenServer

    alias Jido.AgentServer
    alias Jido.Signal

    @quotes [
      "The best way to predict the future is to create it.",
      "Simplicity is the soul of efficiency.",
      "Talk is cheap. Show me the code.",
      "First, solve the problem. Then, write the code."
    ]

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      state = %{
        id: Keyword.fetch!(opts, :id),
        target: Keyword.fetch!(opts, :target),
        interval_ms: Keyword.get(opts, :interval_ms, 50),
        category: Keyword.get(opts, :category, "programming"),
        emit_count: 0,
        max_emits: Keyword.get(opts, :max_emits, 5)
      }

      send(self(), :emit)
      {:ok, state}
    end

    @impl true
    def handle_info(:emit, %{emit_count: count, max_emits: max} = state) when count >= max do
      {:stop, :normal, state}
    end

    def handle_info(:emit, state) do
      new_count = state.emit_count + 1

      signal =
        Signal.new!(
          "sensor.quote",
          %{
            quote: Enum.at(@quotes, rem(new_count - 1, length(@quotes))),
            category: state.category,
            emit_count: new_count,
            sensor_id: state.id
          },
          source: "/sensor/random_quote:#{state.id}"
        )

      AgentServer.cast(state.target, signal)

      Process.send_after(self(), :emit, state.interval_ms)
      {:noreply, %{state | emit_count: new_count}}
    end
  end

  # ===========================================================================
  # WEBHOOK HELPER: Direct signal injection (no sensor process needed)
  # ===========================================================================

  defmodule WebhookHelper do
    @moduledoc false
    alias Jido.AgentServer
    alias Jido.Signal

    def emit_github_event(agent_target, event_type, payload) do
      signal =
        Signal.new!(
          "webhook.github",
          %{event: event_type, payload: payload, received_at: DateTime.utc_now()},
          source: "/webhook/github"
        )

      AgentServer.cast(agent_target, signal)
    end

    def emit_stripe_event(agent_target, event_type, payload) do
      signal =
        Signal.new!(
          "webhook.stripe",
          %{event: event_type, payload: payload, received_at: DateTime.utc_now()},
          source: "/webhook/stripe"
        )

      AgentServer.cast(agent_target, signal)
    end
  end

  # ===========================================================================
  # TESTS
  # ===========================================================================

  describe "sensor demo" do
    test "sensor signals route through signal_routes and update agent state", %{jido: jido} do
      # Start the agent under the per-test isolated Jido instance
      {:ok, agent_pid} =
        Jido.start_agent(jido, QuoteCollectorAgent, id: unique_id("collector"))

      # Start a bounded sensor that emits quote signals
      {:ok, sensor_pid} =
        RandomQuoteSensor.start_link(
          id: unique_id("quote-sensor"),
          target: agent_pid,
          interval_ms: 25,
          category: "programming",
          max_emits: 4
        )

      on_exit(fn ->
        if Process.alive?(sensor_pid) do
          GenServer.stop(sensor_pid, :normal, 500)
        end
      end)

      # Verify quotes were collected via signal routing
      quotes =
        await_state_value(
          agent_pid,
          fn s ->
            quotes = s.agent.state.domain.quotes
            if match?([_, _ | _], quotes), do: quotes
          end,
          timeout: 5_000
        )

      assert length(quotes) >= 2, "Expected at least 2 quotes, got #{length(quotes)}"

      assert Enum.all?(quotes, fn q ->
               is_binary(q.quote) and
                 is_binary(q.category) and
                 is_integer(q.emit_count) and
                 is_binary(q.sensor_id)
             end),
             "Quote structure is invalid"
    end

    test "webhook signals route correctly without a sensor process", %{jido: jido} do
      {:ok, agent_pid} =
        Jido.start_agent(jido, QuoteCollectorAgent, id: unique_id("collector"))

      # Inject webhook signals directly (no sensor process)
      WebhookHelper.emit_github_event(agent_pid, "push", %{
        ref: "refs/heads/main",
        commits: 3,
        repository: "myapp"
      })

      WebhookHelper.emit_stripe_event(agent_pid, "payment_intent.succeeded", %{
        amount: 9900,
        currency: "usd",
        customer: "cus_123"
      })

      # Verify webhook events were recorded correctly
      events =
        await_state_value(
          agent_pid,
          fn s ->
            events = s.agent.state.domain.events
            if match?([_, _ | _], events), do: events
          end,
          timeout: 5_000
        )

      github_event = Enum.find(events, &(&1.source == :github))
      stripe_event = Enum.find(events, &(&1.source == :stripe))

      assert github_event != nil, "GitHub event not found"
      assert github_event.event == "push"
      assert github_event.payload.ref == "refs/heads/main"

      assert stripe_event != nil, "Stripe event not found"
      assert stripe_event.event == "payment_intent.succeeded"
      assert stripe_event.payload.amount == 9900
    end

    test "combined sensor + webhook signals accumulate in agent state", %{jido: jido} do
      {:ok, agent_pid} =
        Jido.start_agent(jido, QuoteCollectorAgent, id: unique_id("collector"))

      # Start sensor
      {:ok, sensor_pid} =
        RandomQuoteSensor.start_link(
          id: unique_id("quote-sensor"),
          target: agent_pid,
          interval_ms: 30,
          category: "integration",
          max_emits: 3
        )

      on_exit(fn ->
        if Process.alive?(sensor_pid), do: GenServer.stop(sensor_pid, :normal, 500)
      end)

      # Wait for some quotes, then inject webhooks
      await_state_value(
        agent_pid,
        fn s -> if s.agent.state.domain.quotes != [], do: true end,
        timeout: 3_000
      )

      # Inject webhooks while sensor is still running
      WebhookHelper.emit_github_event(agent_pid, "pull_request", %{action: "opened"})
      WebhookHelper.emit_stripe_event(agent_pid, "invoice.paid", %{amount: 5000})

      # Verify final state has both quotes and events
      %{quotes: quotes, events: events} =
        await_state_value(
          agent_pid,
          fn s ->
            quotes = s.agent.state.domain.quotes
            events = s.agent.state.domain.events

            if length(quotes) >= 2 and length(events) == 2,
              do: %{quotes: quotes, events: events}
          end,
          timeout: 5_000
        )

      # Should have at least 2 quotes from sensor
      assert length(quotes) >= 2

      # Should have both webhook events
      assert length(events) == 2

      sources = Enum.map(events, & &1.source) |> Enum.sort()
      assert sources == [:github, :stripe]
    end
  end
end
