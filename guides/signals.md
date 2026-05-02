# Signals & Routing

<!-- covers: jido.signals_and_directives.signal_routing -->

Signals carry CloudEvents-style messages through the Jido system, providing a standardized communication envelope between agents.

## What is a Signal?

Signals (`jido_signal` package) are typed messages that trigger agent behavior. They follow the CloudEvents specification, providing:

- **Standardized envelope** - Consistent structure for all inter-agent communication
- **Type-based routing** - Signals are routed to actions based on their `type` field
- **Traceability** - Built-in support for correlation and causation tracking

```
Signal (input) → Router → Agent.cmd/2(action) → {Updated Agent, Directives}
                                                        ↓
                                              Emit Directive → Signal (output)
```

## Creating Signals

Use `Jido.Signal.new!/2,3` to create signals:

```elixir
signal = Jido.Signal.new!("order.placed", %{order_id: 123}, source: "/orders")
```

### Required Fields

| Field | Description | Example |
|-------|-------------|---------|
| `type` | The event type (used for routing) | `"order.placed"`, `"user.created"` |
| `source` | Where the signal originated | `"/orders"`, `"/api"`, `"/worker"` |

### Optional Fields

| Field | Description | Example |
|-------|-------------|---------|
| `subject` | Who/what this is about | `"/users/123"` |
| `data` | The payload (second argument) | `%{order_id: 123}` |

### Examples

```elixir
# Basic signal
signal = Jido.Signal.new!("increment", %{amount: 10}, source: "/user")

# Signal with all fields
signal = Jido.Signal.new!("order.completed", %{
  order_id: 456,
  total: 99.99
}, source: "/checkout", subject: "/orders/456")
```

## Sending Signals to Agents

Once an agent is running via `AgentServer`, send signals using `call/3` or `cast/2`.

### Synchronous (call)

Use `call/3` when you need the updated agent state back:

```elixir
signal = Jido.Signal.new!("increment", %{amount: 10}, source: "/user")

# Default timeout (5000ms)
{:ok, agent} = Jido.AgentServer.call(pid, signal)

# Custom timeout
{:ok, agent} = Jido.AgentServer.call(pid, signal, 10_000)

# Using agent ID instead of pid (requires registry)
{:ok, agent} = Jido.AgentServer.call("agent-id", signal)
```

### Asynchronous (cast)

Use `cast/2` for fire-and-forget signals:

```elixir
signal = Jido.Signal.new!("background.task", %{task_id: "abc"}, source: "/scheduler")

:ok = Jido.AgentServer.cast(pid, signal)
:ok = Jido.AgentServer.cast("agent-id", signal)
```

## Signal Routing

When a signal arrives at an agent, the `SignalRouter` determines which action to execute. Routes are checked in priority order:

1. **Strategy routes** (priority 50+) — via `strategy.signal_routes/1`
2. **Agent routes** (priority 0) — via `agent_module.signal_routes/1`
3. **Plugin routes** (priority -10) — via plugin `signal_patterns` and `signal_routes/1`

### Agent Signal Routes

Declare static routes at compile time inside the agent's
`signal_routes do … end` section:

```elixir
defmodule MyApp.CounterAgent do
  use Jido.Agent

  agent do
    name "counter"
    path :state
    schema [counter: [type: :integer, default: 0]]
  end

  signal_routes do
    route "increment", MyApp.Actions.Increment
    route "decrement", MyApp.Actions.Decrement
    route "reset", MyApp.Actions.Reset
  end
end
```

### Strategy Signal Routes

Strategies can define their own routing via `signal_routes/1`:

```elixir
defmodule MyStrategy do
  use Jido.Agent.Strategy

  @impl true
  def signal_routes(_ctx) do
    [
      {"react.user_query", {:strategy_cmd, :react_start}},
      {"ai.llm_result", {:strategy_cmd, :react_llm_result}}
    ]
  end
end
```

### Plugin / Slice Signal Routes

Plugins and slices declare their routes inside a `signal_routes do … end`
section the same way agents do. The router matches the slice's routes
the moment its module is registered via `extensions: […]`:

```elixir
defmodule MyApp.ChatPlugin do
  use Jido.Plugin

  slice do
    name "chat"
    path :chat
    schema Zoi.object(%{messages: Zoi.list(Zoi.any()) |> Zoi.default([])})
  end

  signal_routes do
    route "chat.send", MyApp.Actions.SendMessage
    route "chat.clear", MyApp.Actions.ClearHistory
  end
end
```

Pattern matching is supported on each `route "type"`:
- `"chat.*"` — matches `chat.message`, `chat.clear`, etc.
- `"chat.**"` — matches `chat.message`, `chat.room.join`, etc.

## Emitting Signals (Directives.Emit)

Actions emit signals using the `Directives.Emit` directive:

```elixir
defmodule MyApp.Actions.ProcessOrder do
  use Jido.Action

  action do
    name "process_order"
    schema [order_id: [type: :integer, required: true]]
  end

  alias Jido.Directives
  alias Jido.Signal

  def run(%{order_id: order_id}, _context) do
    # Process the order...
    
    # Emit a signal to notify completion
    signal = Signal.new!("order.processed", %{order_id: order_id}, source: "/processor")
    
    {:ok, %{status: :processed}, [Directives.emit(signal)]}
  end
end
```

### Emit Helpers

```elixir
alias Jido.Directives

# Basic emit
Directives.emit(signal)

# Emit to a specific adapter (e.g., PubSub)
Directives.emit(signal, {:pubsub, topic: "events"})

# Emit directly to a pid
Directives.emit_to_pid(signal, pid)

# Emit to parent agent (in hierarchies)
Directives.emit_to_parent(agent, signal)
```

## Signal Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        External Systems                          │
│                   (HTTP, PubSub, Sensors, etc.)                  │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼ Signal
┌─────────────────────────────────────────────────────────────────┐
│                         AgentServer                              │
│  Signal → AgentServer.call/cast                                  │
│  → route_signal_to_action (via strategy/agent/plugin routes)      │
│  → Agent.cmd/2                                                   │
│  → process directives                                            │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼ Directives.Emit
┌─────────────────────────────────────────────────────────────────┐
│                       Dispatch Adapters                          │
│               (PubSub, PID, External Systems)                    │
└─────────────────────────────────────────────────────────────────┘
```

## Complete Example

```elixir
# Define an action that responds to signals
defmodule MyApp.Actions.Increment do
  use Jido.Action

  action do
    name "increment"
    schema [amount: [type: :integer, default: 1]]
  end

  def run(params, context) do
    current = Map.get(context.state, :counter, 0)
    {:ok, %{counter: current + params.amount}}
  end
end

# Define an agent with signal routes
defmodule MyApp.CounterAgent do
  use Jido.Agent

  agent do
    name "counter"
    path :state
    schema [counter: [type: :integer, default: 0]]
  end

  signal_routes do
    route "increment", MyApp.Actions.Increment
  end
end

# Use it
{:ok, pid} = Jido.AgentServer.start_link(agent: MyApp.CounterAgent, id: "counter-1")

signal = Jido.Signal.new!("increment", %{amount: 10}, source: "/user")
{:ok, agent} = Jido.AgentServer.call(pid, signal)

agent.state.state.counter
# => 10
```

## Related

- [Core Loop](core-loop.md) — Agent fundamentals
- [Directives](directives.md) — The Emit directive and others
- [Plugins](plugins.md) — Plugin signal patterns
- [jido_signal documentation](https://hexdocs.pm/jido_signal) — Full Signal API
