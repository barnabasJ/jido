# Your First Plugin

**After:** You can refactor "stuff your agent does" into a Plugin with isolated state and routing.

## The Result

Here's what you'll build — a `CounterPlugin` that tracks a counter in
isolated slice state and routes signals to increment it:

```elixir
defmodule MyApp.CounterPlugin do
  use Jido.Plugin

  slice do
    name "counter"
    path :counter
    schema Zoi.object(%{
      value: Zoi.integer() |> Zoi.default(0),
      last_updated: Zoi.any() |> Zoi.optional()
    })
  end

  signal_routes do
    route "counter.increment", MyApp.IncrementAction
  end
end
```

Attach it to an agent:

```elixir
defmodule MyApp.MyAgent do
  use Jido.Agent, extensions: [MyApp.CounterPlugin]

  agent do
    name "my_agent"
  end
end
```

Send a signal:

```elixir
{:ok, pid} = Jido.AgentServer.start_link(agent: MyApp.MyAgent, jido: MyApp.Jido)

signal = Jido.Signal.new!("counter.increment", %{amount: 5}, source: "/app")
{:ok, agent} = Jido.AgentServer.call(pid, signal)

agent.state.counter.value
#=> 5
```

The plugin owns `agent.state.counter` — isolated from other plugins.

## Building It Step by Step

### Step 1: Create the Action

Actions do the actual work. This action increments a counter:

```elixir
defmodule MyApp.IncrementAction do
  use Jido.Action

  action do
    name "increment"
    path :counter
    schema Zoi.object(%{amount: Zoi.integer() |> Zoi.default(1)})
  end

  def run(%{amount: amount}, %{state: counter}) do
    current = counter[:value] || 0

    new_counter = %{
      value: current + amount,
      last_updated: DateTime.utc_now()
    }

    {:ok, new_counter}
  end
end
```

The action declares `path :counter`, so its `state` is the counter slice
itself (not the full agent state). It returns the new slice value — the
framework writes that into `agent.state[:counter]` atomically.

### Step 2: Define the Plugin

Wrap the action in a plugin with state and routing:

```elixir
defmodule MyApp.CounterPlugin do
  use Jido.Plugin

  slice do
    name "counter"
    path :counter
    schema Zoi.object(%{
      value: Zoi.integer() |> Zoi.default(0),
      last_updated: Zoi.any() |> Zoi.optional()
    })
  end

  signal_routes do
    route "counter.increment", MyApp.IncrementAction
  end
end
```

**Required slice fields:**

| Field | Description |
|--------|-------------|
| `name` | Plugin name (letters, numbers, underscores) |
| `path` | Atom slice key in `agent.state` |

**Key optional fields:**

| Field | Description |
|--------|-------------|
| `schema` | Zoi schema for slice state with defaults |
| `config_schema` | Zoi schema for per-agent configuration |
| `signal_routes` section | Static `route "type", Action` entries |
| `subscriptions` section | `subscription Sensor, %{}` entries |
| `schedules` section | `schedule "cron", Action` entries |

### Step 3: Attach to an Agent

```elixir
defmodule MyApp.MyAgent do
  use Jido.Agent, extensions: [MyApp.CounterPlugin]

  agent do
    name "my_agent"
  end
end
```

When the agent is created, the plugin's slice is initialized under its
`path:`.

## State Isolation

Each plugin's slice is its own namespace in `agent.state`:

```elixir
agent = MyApp.MyAgent.new()

agent.state
#=> %{
#=>   counter: %{value: 0, last_updated: nil}  # CounterPlugin slice
#=> }
```

With multiple plugins:

```elixir
defmodule MyApp.MultiPluginAgent do
  use Jido.Agent, extensions: [MyApp.CounterPlugin, MyApp.ChatPlugin]

  agent do
    name "multi_agent"
  end
end

agent = MyApp.MultiPluginAgent.new()

agent.state
#=> %{
#=>   counter: %{value: 0, last_updated: nil},  # CounterPlugin
#=>   chat: %{messages: [], model: "gpt-4"}     # ChatPlugin
#=> }
```

Slices can't accidentally overwrite each other.

## Signal Routing

Declare signal routes at compile time inside the plugin's
`signal_routes do … end` section:

```elixir
defmodule MyApp.CounterPlugin do
  use Jido.Plugin

  slice do
    name "counter"
    path :counter
    schema ...
  end

  signal_routes do
    route "counter.increment", MyApp.IncrementAction
    route "counter.reset", MyApp.ResetAction
  end
end
```

When a signal arrives:

1. Router finds a matching route
2. The corresponding action runs via `cmd/2`
3. State operations update `agent.state`

**Complete example:**

```elixir
# Start the agent
{:ok, pid} = Jido.AgentServer.start_link(agent: MyApp.MyAgent, jido: MyApp.Jido)

# Send increment signal
signal = Jido.Signal.new!("counter.increment", %{amount: 10}, source: "/app")
{:ok, agent} = Jido.AgentServer.call(pid, signal)

agent.state.counter.value
#=> 10

# Send another
signal = Jido.Signal.new!("counter.increment", %{amount: 5}, source: "/app")
{:ok, agent} = Jido.AgentServer.call(pid, signal)

agent.state.counter.value
#=> 15
```

## Per-Agent Configuration

Plugins can declare a `config_schema` for per-agent configuration. The
plain way is to pass a `{Plugin, config}` tuple:

```elixir
defmodule MyApp.ConfigurablePlugin do
  use Jido.Plugin

  slice do
    name "configurable"
    path :configurable
    config_schema Zoi.object(%{
      max_value: Zoi.integer() |> Zoi.default(100)
    })
  end
end

defmodule MyApp.ConfiguredAgent do
  use Jido.Agent, extensions: [{MyApp.ConfigurablePlugin, %{max_value: 500}}]

  agent do
    name "configured_agent"
  end
end

agent = MyApp.ConfiguredAgent.new()
agent.state.configurable.max_value
#=> 500
```

## Contributing a typed config block to the host

A nicer alternative — opt into the *contribution mechanism* and the
plugin's config becomes a typed DSL block on the host agent itself:

```elixir
defmodule MyApp.ConfigurablePlugin do
  use Jido.Plugin
  use Jido.Slice.Extension, host_section: :configurable

  slice do
    name "configurable"
    path :configurable
    config_schema Zoi.object(%{
      max_value: Zoi.integer() |> Zoi.default(100)
    })
  end
end

defmodule MyApp.ConfiguredAgent do
  use Jido.Agent, extensions: [MyApp.ConfigurablePlugin]

  agent do
    name "configured_agent"
  end

  configurable do
    max_value 500
    path :tuned_config  # optionally rename the slice mount path on this host
  end
end
```

Now `agent.state.tuned_config.max_value == 500`, validated at compile
time, and ExDoc renders the `configurable do … end` schema in the
agent's reference page.

## Next Steps

- [Plugins Reference](plugins.md) — Full API reference and lifecycle callbacks
- [Signals & Routing](signals.md) — Signal patterns and routing rules
- [Actions](actions.md) — How actions transform state and emit directives
- [Migration: keyword form to Spark DSL](migration-spark-dsl.md) — Recipes for older code
