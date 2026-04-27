# Migration Guide: Jido 1.x to 2.0

<!-- covers: jido.integrations_and_migration.migration_guidance -->

**After:** You can upgrade from Jido 1.x with minimal surprises.

This guide helps you migrate existing Jido applications to version 2.0. The migration can be done incrementally—start with the minimum changes to get running, then adopt new patterns as needed.

## Breaking Changes Summary

| Area | V1 | V2 | Migration Effort |
|------|----|----|------------------|
| Runtime | Global singleton | Instance-scoped supervisor | Small |
| Agent Lifecycle | `AgentServer.start/1` | `Jido.start_agent/3` | Small-Medium |
| Side Effects | Mixed in callbacks | Directive-based | Medium |
| Messaging | `Jido.Instruction` | CloudEvents Signals | Medium-Large |
| Orchestration | Runners (Simple/Chain) | Strategies + Plans | Medium |
| Actions | `Jido.Actions.*` | `Jido.Tools.*` | Small |
| Validation | NimbleOptions | Zoi schemas | Small-Medium |
| Errors | Ad hoc tuples | Splode structured errors | Small-Medium |
| State Layout | Flat `agent.state.counter` | Scoped `agent.state.__domain__.counter` ([ADR 0008](adr/0008-flat-layout-removed.md)) | Small |

### State Layout: `:__domain__` slice

As of [ADR 0008](adr/0008-flat-layout-removed.md), user-domain state lives under `agent.state.__domain__` by default. Plugin state continues to live under its own slice (`:__pod__`, `:__bus_wiring__`, etc.). Schema-backed fields declared via `use Jido.Agent, schema: [...]` are seeded under `:__domain__`.

**Rewrites needed for agents declared before ADR 0008:**

- Reading user-domain fields:
  ```elixir
  agent.state.counter        # old
  agent.state.__domain__.counter  # new
  ```
- Writing user-domain fields via map-update (rare — prefer `set/2` or action returns):
  ```elixir
  %{agent | state: %{agent.state | counter: 42}}  # old
  %{agent | state: %{agent.state | __domain__: %{agent.state.__domain__ | counter: 42}}}  # new
  # or:
  %{agent | state: put_in(agent.state, [:__domain__, :counter], 42)}
  ```
- `new(state: ...)` and `set/2` **auto-wrap** flat attrs into `:__domain__`, so common constructor calls (`new(state: %{counter: 10})`) keep working.
- State-op directives (`%SetPath{}`, `%DeletePath{}`, etc.) still operate on full `agent.state` — prefix paths with `:__domain__` to target user-domain fields.
- Scoped actions (`use Jido.Agent.ScopedAction, state_key: :__domain__`) receive just their slice as `ctx.state` and return `{:ok, new_slice}` with wholesale-replace semantics.

## Migration Path Overview

Choose your migration depth based on your timeline and needs:

1. **Minimal** (1-2 hours): Add supervision tree, update agent starts
2. **Intermediate** (1 day): Adopt Plugins, use Directives for side effects
3. **Full** (1-2 weeks): Pure `cmd/2`, Zoi schemas, Strategies, Plans

## Step 1: Add Jido to Your Supervision Tree

V2 uses instance-scoped supervisors instead of a global singleton. Define an instance module and add it to your supervision tree.

```elixir
# lib/my_app/jido.ex
defmodule MyApp.Jido do
  use Jido, otp_app: :my_app
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Jido,
  max_tasks: 1000,
  agent_pools: []
```

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Add Jido as a supervised child
      MyApp.Jido,
      
      # Your other children...
      MyApp.Repo,
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

The instance module provides functions for managing agents that you'll use throughout your application.

## Step 2: Update Agent Starts

Replace direct `start_link` calls with your instance module's `start_agent/2`.

### Before (V1)

```elixir
# Starting an agent directly
{:ok, pid} = MyAgent.start_link(id: "agent-1")

# Or via AgentServer
{:ok, pid} = Jido.AgentServer.start_link(
  agent: MyAgent,
  agent_opts: [id: "agent-1"]
)
```

### After (V2)

```elixir
# Start via your instance module
{:ok, pid} = MyApp.Jido.start_agent(MyAgent, id: "agent-1")

# With additional options
{:ok, pid} = MyApp.Jido.start_agent(MyAgent,
  id: "agent-1",
  initial_state: %{counter: 0},
  strategy: Jido.Strategy.Direct
)
```

### Why This Matters

- **Discovery**: Agents are automatically registered and discoverable via `MyApp.Jido.whereis/1`
- **Lifecycle**: The supervisor handles restarts and cleanup
- **Hierarchy**: Enables parent-child agent relationships

## Step 3: Update Lifecycle Calls

Replace direct process calls with your instance module's functions.

### Before (V1)

```elixir
# Stopping an agent
AgentServer.stop(pid)
GenServer.stop(pid)

# Finding an agent
pid = Process.whereis(:"agent_agent-1")
```

### After (V2)

```elixir
# Stop via instance module
MyApp.Jido.stop_agent("agent-1")

# Find via discovery
pid = MyApp.Jido.whereis("agent-1")

# List all agents
agents = MyApp.Jido.list_agents()
```

## Step 4: Adopt Directives for Side Effects

V2 separates pure state transformations from side effects using Directives. This is the biggest conceptual change and can be adopted incrementally.

### Before (V1): Ad Hoc Side Effects

```elixir
defmodule MyAgent do
  use Jido.Agent

  def handle_result(agent, result) do
    # Side effect mixed with state logic
    Phoenix.PubSub.broadcast(MyApp.PubSub, "events", result)
    
    # External API call
    HTTPoison.post!("https://api.example.com/webhook", result)
    
    # Update state
    %{agent | state: Map.put(agent.state, :last_result, result)}
  end
end
```

### After (V2): Declarative Directives

```elixir
defmodule MyAgent do
  use Jido.Agent
  
  alias Jido.Agent.Directive
  alias Jido.Signal

  def cmd(agent, %Signal{type: "result.received"} = signal) do
    result = signal.data
    
    # Pure state update
    updated_agent = %{agent | 
      state: Map.put(agent.state, :last_result, result)
    }
    
    # Directives describe effects, don't execute them
    directives = [
      Directive.emit(
        Signal.new!("result.processed", result, source: "/agent"),
        {:pubsub, topic: "events"}
      ),
      Directive.emit(
        Signal.new!("webhook.send", result, source: "/agent"),
        {:http, url: "https://api.example.com/webhook"}
      )
    ]
    
    {updated_agent, directives}
  end
end
```

### Core Directives

| Directive | Purpose | Example |
|-----------|---------|---------|
| `Emit` | Dispatch a signal via adapters | `Directive.emit(signal, {:pubsub, topic: "events"})` |
| `Spawn` | Spawn a generic BEAM process | `Directive.spawn({Task, fn -> work() end})` |
| `SpawnAgent` | Spawn a child agent with hierarchy | `Directive.spawn_agent(ChildAgent, :child_1, opts: %{id: "child-1"})` |
| `StopChild` | Stop a tracked child agent | `Directive.stop_child("child-1")` |
| `Schedule` | Schedule a delayed message | `Directive.schedule(5_000, signal)` |
| `Stop` | Stop the agent process | `Directive.stop(:normal)` |
| `Error` | Signal an error | `Directive.error(:validation_failed)` |

## Step 5: Use CloudEvents Signals

V2 uses CloudEvents-compliant signals instead of ad hoc messages.

### Before (V1): Ad Hoc Messages

```elixir
# Sending messages
send(pid, {:task_complete, %{id: 123, result: "done"}})
GenServer.cast(pid, {:process, data})

# Handling in agent
def handle_info({:task_complete, payload}, state) do
  # process...
  {:noreply, state}
end
```

### After (V2): Structured Signals

```elixir
alias Jido.Signal

# Creating signals
signal = Signal.new!(
  "task.completed",
  %{id: 123, result: "done"},
  source: "/workers/processor-1"
)

# Dispatching to a specific agent (synchronous)
{:ok, agent} = Jido.AgentServer.call(pid, signal)

# Or asynchronously
:ok = Jido.AgentServer.cast(pid, signal)

# Handling in agent (via cmd/2)
def cmd(agent, %Signal{type: "task.completed"} = signal) do
  result = signal.data.result
  {update_state(agent, result), []}
end
```

### Signal Anatomy

```elixir
%Jido.Signal{
  type: "order.placed",           # Event type (required)
  source: "/checkout/web",        # Origin (required)
  id: "550e8400-...",             # Unique ID (auto-generated)
  data: %{order_id: 123},         # Payload
  subject: "user/456",            # Optional subject
  time: ~U[2024-01-15 10:30:00Z]  # Timestamp
}
```

## Step 6: Migrate Actions to Tools

The `Jido.Actions.*` namespace has been renamed to `Jido.Tools.*`.

### Before (V1)

```elixir
defmodule MyApp.Actions.SendEmail do
  use Jido.Action,
    name: "send_email",
    description: "Sends an email",
    schema: [
      to: [type: :string, required: true],
      subject: [type: :string, required: true]
    ]

  @impl true
  def run(params, _context) do
    # send email...
    {:ok, %{sent: true}}
  end
end
```

### After (V2)

```elixir
defmodule MyApp.Tools.SendEmail do
  use Jido.Tool,
    name: "send_email",
    description: "Sends an email"

  @schema Zoi.struct(__MODULE__, %{
    to: Zoi.string(description: "Recipient email"),
    subject: Zoi.string(description: "Email subject")
  })

  @impl true
  def run(params, _context) do
    {:ok, %{sent: true}}
  end
end
```

## Step 7: Adopt Zoi Schemas

V2 uses Zoi for schema definitions instead of NimbleOptions.

### Before (V1): NimbleOptions

```elixir
defmodule MyAgent do
  use Jido.Agent,
    name: "my_agent",
    schema: [
      name: [type: :string, required: true],
      count: [type: :integer, default: 0],
      tags: [type: {:list, :string}, default: []]
    ]
end
```

### After (V2): Zoi Schemas

```elixir
defmodule MyAgent do
  use Jido.Agent,
    name: "my_agent"

  @schema Zoi.struct(__MODULE__, %{
    name: Zoi.string(description: "Agent name"),
    count: Zoi.integer(default: 0),
    tags: Zoi.list(Zoi.string()) |> Zoi.default([])
  }, coerce: true)

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
end
```

### Zoi Benefits

- Single source of truth for types, defaults, and validation
- Automatic typespec generation
- Coercion support
- Better error messages

## Step 8: Migrate to Splode Errors

V2 uses Splode for structured error handling.

### Before (V1): Ad Hoc Tuples

```elixir
def process(data) do
  case validate(data) do
    :ok -> {:ok, result}
    :error -> {:error, :validation_failed}
    {:error, reason} -> {:error, {:processing_error, reason}}
  end
end
```

### After (V2): Splode Errors

```elixir
defmodule MyApp.Errors do
  use Splode, error_classes: [
    validation: MyApp.Errors.Validation,
    processing: MyApp.Errors.Processing
  ]
end

defmodule MyApp.Errors.Validation.InvalidInput do
  use Splode.Error, fields: [:field, :reason], class: :validation
  
  def message(%{field: field, reason: reason}) do
    "Invalid #{field}: #{reason}"
  end
end

# Usage
def process(data) do
  case validate(data) do
    :ok -> 
      {:ok, result}
    {:error, field, reason} -> 
      {:error, MyApp.Errors.Validation.InvalidInput.exception(
        field: field, 
        reason: reason
      )}
  end
end
```

## New Features in V2 (Optional)

These features are new in V2 and can be adopted as needed:

### Parent-Child Agent Hierarchy

```elixir
def cmd(agent, %Signal{type: "spawn.worker"} = signal) do
  {agent, [
    Directive.spawn_agent(WorkerAgent, 
      id: "worker-#{signal.data.id}",
      parent: agent
    )
  ]}
end

# Child can emit to parent
Directive.emit_to_parent(child_agent, signal)
```

If you are adopting the newer orphan lifecycle in current Jido releases, note
these semantics:

- `on_parent_death: :continue` and `:emit_orphan` now clear stale current-parent refs
- orphaned children keep former-parent provenance in `orphaned_from` / `__orphaned_from__`
- `emit_to_parent/3` returns `nil` while orphaned until a new parent explicitly adopts the child
- adopted child restarts now rehydrate the current parent binding from `Jido.RuntimeStore`

That behavior is more correct for logical hierarchies, but code that relied on
stale `state.parent` or `agent.state.__parent__` after parent death must be
updated. See [Orphans & Adoption](orphans.md) for the full lifecycle.

### Plugin System

```elixir
defmodule MyAgent do
  use Jido.Agent,
    plugins: [
      MyApp.Plugins.WebSearch,
      MyApp.Plugins.DataAnalysis
    ]
end
```

### Strategy Pattern

```elixir
# Direct execution (default)
MyApp.Jido.start_agent(MyAgent, 
  strategy: Jido.Strategy.Direct
)

# FSM-based execution
MyApp.Jido.start_agent(MyAgent, 
  strategy: Jido.Strategy.FSM,
  strategy_opts: [initial_state: :idle]
)
```

### Telemetry

V2 emits telemetry events for observability:

```elixir
:telemetry.attach(
  "my-handler",
  [:jido, :agent, :cmd, :stop],
  fn _event, measurements, metadata, _config ->
    Logger.info("cmd took #{measurements.duration}ns")
  end,
  nil
)
```

## Common Migration Patterns

### Pattern 1: Gradual Directive Adoption

You don't need to convert all side effects at once. Start with the most critical paths:

```elixir
def cmd(agent, signal) do
  # New code uses directives
  result = process(signal)
  
  # Legacy code still works (but should be migrated)
  LegacyNotifier.notify(result)
  
  {%{agent | state: result}, [
    Directive.emit(Signal.new!("processed", result, source: "/agent"), :default)
  ]}
end
```

### Pattern 2: Wrapper for Legacy Agents

If you have many agents, your instance module already provides the wrapper:

```elixir
# Define your instance module once
defmodule MyApp.Jido do
  use Jido, otp_app: :my_app
end

# Then use it throughout your application
MyApp.Jido.start_agent(MyAgent, id: "agent-1")
MyApp.Jido.stop_agent("agent-1")
```

### Pattern 3: Signal Adapter for Legacy Messages

Bridge old message formats to signals:

```elixir
def handle_info({:legacy_event, payload}, state) do
  signal = Signal.new!("legacy.event", payload, source: "/legacy")
  handle_info(signal, state)
end
```

## Troubleshooting

### "Agent not found" errors

Ensure you're using the correct Jido instance name:

```elixir
# Wrong
Jido.start_agent(Jido, MyAgent, id: "test")

# Right
Jido.start_agent(MyApp.Jido, MyAgent, id: "test")
```

### Directives not executing

Directives are only executed when returned from `cmd/2`. Ensure you're returning them:

```elixir
# Wrong - directive is created but not returned
def cmd(agent, signal) do
  Directive.emit(signal, :default)
  {agent, []}
end

# Right
def cmd(agent, signal) do
  {agent, [Directive.emit(signal, :default)]}
end
```

### Schema validation errors

If migrating from NimbleOptions, ensure required fields are marked:

```elixir
# Zoi doesn't have `required: true`, fields are required by default
# Use Zoi.optional() for optional fields
@schema Zoi.struct(__MODULE__, %{
  name: Zoi.string(),                           # Required
  description: Zoi.string() |> Zoi.optional()   # Optional
})
```

## ADR 0014/0015/0016 — Slice / Middleware / Plugin and lifecycle rewrite

ADR 0014 collapses the old plugin surface into three tiers (Slice /
Middleware / Plugin), retires `Jido.Agent.Strategy`, and replaces the
underscore-wrapped slice convention (`:__domain__`, `:__thread__`, …) with
flat-atom paths declared by the agent and each plugin. ADR 0015 makes thaw
indistinguishable from fresh start. ADR 0016 replaces `await_completion/2`
and the bare `AgentServer.call/2 → %State{}` with selector-based
primitives. The migration recipes are below; for the full rationale see
[ADR 0014](adr/0014-slice-middleware-plugin.md),
[ADR 0015](adr/0015-agent-start-is-signal-driven.md),
[ADR 0016](adr/0016-agent-server-ack-and-subscribe.md).

> **No migration shims ship.** Pre-refactor checkpoints are not forward-
> compatible (per ADR 0014's "no external users" assumption). Local-dev
> and test-fixture checkpoints from before this PR must be regenerated.

### Plugin surface — the table

| Old shape | New shape | Notes |
|---|---|---|
| `use Jido.Plugin, state_key: :x` | `use Jido.Plugin, path: :x` | Mechanical rename. |
| `mount/2` callback | Schema defaults; per-agent config; or wrapper macro; or lifecycle action | See "`mount/2` retired — four replacement patterns" below. |
| `handle_signal/2` callback | `on_signal/4` Middleware (before-next) | `next.(signal, ctx)` to pass through. |
| `transform_result/3` callback | `on_signal/4` Middleware (after-next) | Walk directives returned from `next.(signal, ctx)`. |
| `on_checkpoint/2` / `on_restore/2` | `Jido.Persist.Transform` behaviour (`externalize/1` / `reinstate/1`) | Persister middleware applies them automatically. |
| Dynamic `signal_routes/1` callback | Static `signal_routes:` keyword | Branch inside the action if conditional logic is needed. |
| `Jido.Agent.ScopedAction` | `use Jido.Action, path: :x` | Path-required on every action. |
| `Jido.Actions.Status.MarkCompleted` and friends | Inline a small action that writes `slice.status = :completed` | The convention isn't a framework concept anymore. |

### `mount/2` retired — four replacement patterns

Per ADR 0014's S2 resolution. Pick whichever applies to your callback:

1. **Nothing (`{:ok, nil}`)** — delete the callback. Schema defaults seed the slice automatically.
2. **Echo per-agent config into the slice** — declare a `schema:` matching the config, and the per-agent `{Plugin, %{...}}` map merges in at `Agent.new/1`. Zero code.
3. **Compile-time derivation from agent module** — wrap `Agent.new/1` in a macro (see [`Jido.Pod`](../lib/jido/pod.ex)). The wrapper computes state from `__MODULE__`'s metadata before delegating.
4. **Runtime-derived (rare)** — declare a Slice action routed on `jido.agent.lifecycle.starting`. The lifecycle signal fires inside `AgentServer.init/1` before any user signal.

### Action callback shape

```elixir
# Before
def run(params, context) do
  {:ok, %{counter: params.value}}
end

# After
def run(%Jido.Signal{data: params}, slice, _opts, ctx) do
  {:ok, %{slice | counter: params.value}}
end
```

Four args, always. The action receives the full slice value (its
declared `path:`'s state) as `slice` and returns the **complete new
slice** — partial-map merging is gone.

### No more deep-merge

```elixir
# Before — partial map, framework deep-merged
def run(_params, _context), do: {:ok, %{counter: 1}}

# After — return the full slice
def run(_signal, slice, _opts, _ctx), do: {:ok, %{slice | counter: 1}}
```

If you need to update a nested field outside the action's declared
slice, return a `%Jido.Agent.SliceUpdate{slices: %{other_slice: new_value}}`
in place of the slice value. The action's `path:` stays single-valued
(its primary slice); secondary slices listed in `slices:` are explicitly
bridged. See [ADR 0019 §3](adr/0019-actions-mutate-state-directives-do-side-effects.md#3-multi-slice-and-cross-slice-writes)
and [Actions — Multi-slice returns](actions.md#multi-slice-returns).

### `Jido.Agent.ScopedAction` folded in

```elixir
# Before
defmodule MyAction do
  use Jido.Agent.ScopedAction, state_key: :x
end

# After
defmodule MyAction do
  use Jido.Action, path: :x
end
```

### `Jido.Actions.Status.MarkCompleted` removed

Inline the convention in your own code:

```elixir
defmodule MyApp.Actions.MarkCompleted do
  use Jido.Action, name: "mark_completed", path: :work, schema: []

  def run(_signal, slice, _opts, _ctx) do
    {:ok, %{slice | status: :completed}}
  end
end
```

### `error_policy:` removed (no direct replacement in this PR)

The old `error_policy: :log_only | :stop_on_error` agent option is gone;
the error-handling model is deferred to a follow-up PR. In the meantime,
either:

(a) **Roll your own middleware** — scan `%Error{}` directives after
    `next.(signal, ctx)` and react:

```elixir
defmodule MyApp.LogOnly do
  use Jido.Middleware
  require Logger

  @impl true
  def on_signal(signal, ctx, _opts, next) do
    {ctx, dirs} = next.(signal, ctx)

    Enum.each(dirs, fn
      %Jido.Agent.Directive.Error{reason: r} ->
        Logger.error("error in #{signal.type}: #{inspect(r)}")
      _ -> :ok
    end)

    {ctx, dirs}  # swallow errors — they don't propagate
  end
end
```

(b) **Translate error → stop** — append a `%Stop{}` directive when an
    error appears:

```elixir
def on_signal(signal, ctx, _opts, next) do
  {ctx, dirs} = next.(signal, ctx)

  if Enum.any?(dirs, &match?(%Jido.Agent.Directive.Error{}, &1)) do
    {ctx, dirs ++ [%Jido.Agent.Directive.Stop{reason: :errored}]}
  else
    {ctx, dirs}
  end
end
```

### `Jido.Await` removed

`Jido.Await.completion/3` and the `Jido.{await,await_child,...}`
defdelegates are gone. Rewrite to `AgentServer.subscribe/4` with a
selector matching whatever terminal-status convention you use:

```elixir
{:ok, ref} =
  Jido.AgentServer.subscribe(
    server,
    "**",
    fn %Jido.AgentServer.State{agent: agent} ->
      case agent.state[:work] do
        %{status: :completed, result: r} -> {:ok, r}
        %{status: :failed, error: e} -> {:error, e}
        _ -> :skip
      end
    end,
    once: true
  )

receive do
  {:jido_subscription, ^ref, %{result: result}} -> result
after
  10_000 ->
    Jido.AgentServer.unsubscribe(server, ref)
    {:error, :timeout}
end
```

### `Jido.AgentServer.Status` removed

Use `AgentServer.state/1` and inspect whatever shape you need:

```elixir
{:ok, state} = Jido.AgentServer.state(server)
state.agent.state[:work].status
```

### Ctx threading

`current_user`, `trace_id`, tenant, and similar per-signal context now
live on `signal.extensions[:jido_ctx]` on the wire and are promoted to an
explicit `ctx` argument at action / middleware / directive-exec
boundaries. The new ack/subscribe primitives accept a `ctx:` keyword:

```elixir
{:ok, signal} = Jido.Signal.new(%{type: "submit", data: %{...}})

Jido.AgentServer.cast_and_await(server, signal, my_selector,
  ctx: %{current_user: user, trace_id: trace_id})
```

The agent and inner middleware see the merged ctx.

### Pre-refactor checkpoints are not forward-compatible

Per ADR 0014's "no external users exist" assumption, no migration pass
ships. Local dev or test-fixture checkpoints from before this PR should be
regenerated by running the post-refactor code from fresh.

### `Directive.emit_to_parent/3` removed

Use `Directive.emit_to_pid(signal, ctx.parent.pid, opts)` with the
`ctx.parent` key seeded at signal receipt. Guard against the
orphaned case (`ctx.parent == nil`):

```elixir
def run(_signal, _slice, _opts, ctx) do
  parent_emit =
    if ctx.parent,
      do: [Directive.emit_to_pid(reply_signal, ctx.parent.pid)],
      else: []

  {:ok, slice, parent_emit}
end
```

### Retry middleware vs Persister IO failures

`Jido.Middleware.Retry` *can* cover Persister IO failures — *if* Retry is
positioned outside Persister in the middleware chain. Persister blocks on
thaw/hibernate IO synchronously; if it raises, Retry (when wrapping)
catches the exception and re-invokes `next`.

Chain ordering is user-declared. Put Retry first if you want
retry-on-thaw:

```elixir
middleware: [Jido.Middleware.Retry, Jido.Middleware.Persister, ...]
```

The error-handling model is otherwise user-owned in this PR; the
follow-up PR formalizes it.

### Hibernate-on-terminate vs supervisor shutdown timeout

`jido.agent.lifecycle.stopping` emits at the top of `terminate/2`;
Persister blocks on hibernate IO synchronously. If the IO exceeds the
supervisor's `shutdown:` timeout (default 5_000 ms), the process is
killed mid-write and the checkpoint is partial. The bound is the
supervisor's timeout, not anything the framework enforces. If you have a
slow storage adapter, bump `shutdown:` accordingly when configuring the
agent's child_spec.

### `InstanceManager.get/3` semantics change

Previously `get/3` thawed synchronously before returning. Now it returns
the pid as soon as the process is alive; thaw runs inside AgentServer's
`init/1` via the Persister middleware reacting to
`jido.agent.lifecycle.starting`.

Callers that assumed "get returned pid ⇒ thawed state available" must
insert `await_ready/2` between get and first signal send:

```elixir
{:ok, pid} = Jido.Agent.InstanceManager.get(:sessions, key)
:ok = Jido.AgentServer.await_ready(pid)         # thaw + reconcile complete
:ok = Jido.AgentServer.cast(pid, signal)
```

InstanceManager does not wrap `await_ready` automatically — liveness
vs. readiness is the caller's concern.

## Tagged-tuple return shape (ADR 0018)

### Action and `cmd` return shapes are tagged tuples

**Old:**

- `run/4` returned `{:ok, slice} | {:ok, slice, directive | [directive]} | {:error, reason}`.
- `cmd/2` returned `{agent, directives}` regardless of outcome.
- Errors went into `dirs` as `%Directive.Error{}` and were logged.

**New:**

- `run/4` returns `{:ok, slice, [directive]} | {:error, reason}` —
  always a 3-tuple on success, list of directives even if empty.
- `cmd/2` returns `{:ok, agent, [directive]} | {:error, reason}`.
- Multi-instruction `cmd` is **all-or-nothing**: the first error halts
  the batch, the input agent is returned via the error branch, and no
  directives execute.

**Recipes:**

- An action that did `{:ok, %{slice | x: 1}}` becomes `{:ok, %{slice | x: 1}, []}`.
- An action that did `{:ok, slice, %Emit{...}}` becomes `{:ok, slice, [%Emit{...}]}`.
- An action that did `{:error, reason}` is unchanged. Bare-atom and
  binary `reason` values are wrapped into `%Jido.Error.ExecutionError{}`
  by the framework via `Jido.Error.from_term/1`, so consumers always see
  a structured error.
- Callers that did `{agent, dirs} = MyAgent.cmd(agent, instructions)` now do:

  ```elixir
  case MyAgent.cmd(agent, instructions) do
    {:ok, agent, dirs} -> ...
    {:error, reason} -> ...
  end
  ```

### `cast_and_await/4` selectors no longer need to encode action errors

**Old:** the selector had to read slice fields the action wrote on the
failure path. If you forgot to write them, the caller hung until timeout.

**New:** the framework delivers `{:error, reason}` directly to the
caller when the chain returns an error; the selector is skipped. Write
the selector to handle the success path only.

```elixir
{:ok, value} =
  AgentServer.cast_and_await(pid, signal, fn %State{agent: agent} ->
    case agent.state.app.status do
      :written -> {:ok, agent.state.app.value}
      _        -> {:error, :not_yet}
    end
  end)
```

If the action errored, `result` is `{:error, %Jido.Error.ExecutionError{...}}`
without the selector ever running.

`AgentServer.call/2` is unchanged: it still returns `{:ok, agent}`
regardless of chain outcome. Use `cast_and_await/4` when you need
error-aware semantics.

### Middleware

`on_signal/4` and `next.(signal, ctx)` both return the same shape:

```elixir
{:ok, ctx, [directive]} | {:error, ctx, reason}
```

The error tuple carries `ctx` so middleware-staged state mutations
(e.g. `Persister` setting `ctx.agent` to the thawed agent) commit to
`state.agent` regardless of the action's outcome. Action-level rollback
lives inside `cmd/2` — the input agent flows back into ctx unchanged on
error, so prior middleware mutations survive. Middleware that wrapped
`next` should match on both branches:

```elixir
def on_signal(signal, ctx, _opts, next) do
  case next.(signal, ctx) do
    {:ok, ctx, dirs}      -> {:ok, augment(ctx), dirs}
    {:error, ctx, reason} -> {:error, augment(ctx), reason}
  end
end
```

### `Retry` middleware now triggers on `{:error, _}`, not on Error directives

If you were relying on Retry firing because an action emitted
`%Directive.Error{}` for logging, that behavior is gone. Retry now fires
only on `{:error, _}` returns from the chain. To get
logging-without-retry, emit the `%Error{}` from a different middleware
on the success path (or use `Logger` directly).

## Getting Help

- [Jido Documentation](https://hexdocs.pm/jido)
- [GitHub Issues](https://github.com/agentjido/jido/issues)
- [Changelog](https://github.com/agentjido/jido/blob/main/CHANGELOG.md)
