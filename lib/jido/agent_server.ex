defmodule Jido.AgentServer do
  @moduledoc """
  GenServer runtime for Jido agents.

  AgentServer is the "Act" side of the Jido framework: while Agents "think"
  (pure decision logic via `cmd/2`), AgentServer "acts" by executing the
  directives they emit. Signal routing happens in AgentServer, keeping
  Agents purely action-oriented.

  ## Architecture

  - Single GenServer per agent under `Jido.AgentSupervisor`
  - Signals process inline inside the triggering handler; the Erlang
    mailbox is the only queue (see ADR 0009)
  - Registry-based naming via `Jido.Registry`
  - Logical parent-child hierarchy via state tracking + monitors

  Jido's parent-child hierarchy is **logical**, not OTP supervisory ancestry.
  Parent and child agents are still OTP peers under a supervisor; the parent
  relationship is represented explicitly with `Jido.AgentServer.ParentRef`,
  runtime monitors, and lifecycle signals.

  ## Public API

  - `start/1` - Start under DynamicSupervisor
  - `start_link/1` - Start linked to caller
  - `call/4` - Synchronous signal processing with selector projection
  - `cast/3` - Asynchronous signal processing
  - `state/3` - Synchronous selector-driven state read (no signal pipeline)
  - `whereis/1` - Registry lookup by ID (default registry)
  - `whereis/2` - Registry lookup by ID (specific registry)

  ## Signal Flow

  ```
  Signal → AgentServer.call/4 (or cast/3)
        → middleware chain (`on_signal/4` wrap)
            → routing → Agent.cmd/2 → {agent, directives}
        → Directives executed inline via DirectiveExec protocol
        → call/4 selector runs over post-pipeline state and the result
          is returned to the caller
  ```

  Signal routing is owned by AgentServer, not the Agent. Plugins and the
  agent itself can define `signal_routes/1` to map signal types to action
  modules. Unmatched signals fall back to `{signal.type, signal.data}` as
  the action.

  ## Options

  - `:jido` - Jido instance name for registry scoping (default: `Jido`)
  - `:agent_module` - Agent module (required). The agent struct is always
    constructed via `agent_module.new(id: ..., state: ...)`.
  - `:id` - Instance ID (auto-generated if not provided)
  - `:initial_state` - Initial state map for agent
  - `:registry` - Registry module (default: `Jido.Registry`)
  - `:default_dispatch` - Default dispatch config for Emit directives (fallback: current agent pid)
  - `:middleware` - List of `module()` or `{module(), opts_map}` middleware appended at runtime
  - `:parent` - Parent reference for hierarchy
  - `:on_parent_death` - Behavior when parent dies:
    - `:stop` - stop the child
    - `:continue` - keep running and become orphaned
    - `:emit_orphan` - become orphaned and process `jido.agent.orphaned`
  - `:spawn_fun` - Custom function for spawning children
  - `:debug` - Enable debug mode with event buffer (default: `false`)

  ## Examples

      # Using global Jido instance (default)
      {:ok, pid} = AgentServer.start_link(agent_module: SimpleAgent)

      # Using a named Jido instance
      {:ok, pid} = AgentServer.start_link(jido: MyApp.Jido, agent_module: MyAgent)

      # With explicit id and initial state
      {:ok, pid} = AgentServer.start_link(
        agent_module: MyAgent,
        id: "my-id",
        initial_state: %{counter: 42}
      )

  ## Completion Detection

  Agents signal completion via **state**, not process death:

      # In an action, set the terminal status on the agent's slice:
      slice = put_in(slice, [:status], :completed)
      slice = put_in(slice, [:last_answer], answer)
      {:ok, slice}

      # External code polls for completion via a selector:
      {:ok, status} =
        AgentServer.state(server, fn s ->
          domain = s.agent_module.path()
          case get_in(s.agent.state, [domain, :status]) do
            :completed -> {:ok, {:completed, get_in(s.agent.state, [domain, :last_answer])}}
            :failed -> {:ok, {:failed, get_in(s.agent.state, [domain, :error])}}
            _ -> {:ok, :still_running}
          end
        end)

  This follows Elm/Redux semantics where completion is a state concern.
  The process stays alive until explicitly stopped or supervised.

  **Do NOT** use `{:stop, ...}` from DirectiveExec for normal completion—this
  causes race conditions with async work and skips lifecycle hooks.
  See `Jido.AgentServer.DirectiveExec` for details.

  ## Debugging

  AgentServer can record recent events in an in-memory ring buffer (max 50)
  to help diagnose what happened inside a running agent.

  Enable at start:

      {:ok, pid} = AgentServer.start_link(agent: MyAgent, debug: true)

  Or toggle at runtime:

      :ok = AgentServer.set_debug(pid, true)

  Retrieve recent events (newest-first):

      {:ok, events} = AgentServer.recent_events(pid, limit: 10)

  Each event has the shape `%{at: monotonic_ms, type: atom(), data: map()}`.
  Event types include `:signal_received` and `:directive_started`.

  Returns `{:error, :debug_not_enabled}` if debug mode is off.

  > **Note:** This is a development aid, not an audit log. Events are not
  > persisted and the buffer has fixed capacity.

  ## Orphans and Adoption

  If a child is configured with `on_parent_death: :continue` or `:emit_orphan`,
  the runtime clears the current parent reference immediately when the logical
  parent dies:

  - `state.parent` becomes `nil`
  - the former parent is preserved in `state.orphaned_from`

  Identity (`partition`, `parent`, `orphaned_from`) lives only on
  `%AgentServer.State{}`; it is no longer mirrored into `agent.state`.
  Actions reach the current values via the `ctx` arg of `run/4` and emitted
  identity-transition signals (`jido.agent.identity.*`).

  Reattachment is explicit. A replacement parent can adopt the live child with
  `Jido.Agent.Directive.adopt_child/3`, which refreshes the child's live parent
  reference and monitoring relationship.

  Relationship bindings are mirrored into `Jido.RuntimeStore`, so when a child
  later restarts it rehydrates its current logical parent from instance runtime
  state instead of falling back to stale startup metadata.

  ## Waiting Primitives

  Two selector-based primitives let callers wait on agent activity:

  - `call/4` — synchronous request. The caller's selector runs after the
    outermost middleware unwinds and the signal's directives have executed;
    the tagged result is returned to the caller. The same selector contract
    applies as `subscribe/4` (no `:skip` — the caller is blocking).
  - `subscribe/4` + `unsubscribe/2` — ambient subscribe on a signal pattern
    plus a selector. Matching signals fire the selector and dispatch
    `{:ok, _}` / `{:error, _}` to the subscriber; `:skip` keeps listening.

  Both fire after the outermost middleware unwinds, so retry middleware
  that re-invokes `next` produces exactly one return/notification per
  triggering signal.
  """

  use GenServer

  require Logger

  alias Jido.AgentServer.{
    ChildInfo,
    CronRuntimeSpec,
    DirectiveExec,
    Options,
    ParentRef,
    SignalRouter,
    State,
    StopChildRuntime
  }

  alias Jido.Agent.Directive

  alias Jido.AgentServer.Signal.{
    ChildAdopted,
    ChildExit,
    ChildStarted,
    CronDied,
    CronRestarted,
    IdentityOrphaned,
    LifecycleReady,
    LifecycleStarting,
    LifecycleStopping,
    Orphaned,
    ParentDied,
    PartitionAssigned
  }

  alias Jido.Config.Defaults
  alias Jido.RuntimeStore
  alias Jido.Sensor.Runtime, as: SensorRuntime
  alias Jido.Signal
  alias Jido.Signal.Router, as: JidoRouter
  alias Jido.Telemetry.Formatter
  alias Jido.Tracing.Context, as: TraceContext
  alias Jido.Tracing.Trace

  @type server :: pid() | atom() | {:via, module(), term()} | String.t()
  @cron_restart_base_ms 500
  @cron_restart_max_ms 30_000
  @relationship_hive :relationships

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts an AgentServer under `Jido.AgentSupervisor`.

  ## Examples

      {:ok, pid} = Jido.AgentServer.start(agent: MyAgent)
      {:ok, pid} = Jido.AgentServer.start(agent: MyAgent, id: "my-agent")
  """
  @spec start(keyword() | map()) :: DynamicSupervisor.on_start_child()
  def start(opts) do
    child_spec = {__MODULE__, opts}

    jido_instance =
      if is_list(opts), do: Keyword.get(opts, :jido), else: Map.get(opts, :jido)

    supervisor =
      case jido_instance do
        nil -> Jido.AgentSupervisor
        instance -> Jido.agent_supervisor_name(instance)
      end

    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  @doc """
  Starts an AgentServer linked to the calling process.

  ## Options

  See module documentation for full list of options.

  ## Examples

      {:ok, pid} = Jido.AgentServer.start_link(agent: MyAgent)
      {:ok, pid} = Jido.AgentServer.start_link(agent: MyAgent, id: "custom-123")
      {:ok, pid} = Jido.AgentServer.start_link(jido: MyApp.Jido, agent: MyAgent)
  """
  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) or is_map(opts) do
    # Extract GenServer options (like :name) from agent opts
    {genserver_opts, agent_opts} = extract_genserver_opts(opts)
    GenServer.start_link(__MODULE__, agent_opts, genserver_opts)
  end

  defp extract_genserver_opts(opts) when is_list(opts) do
    case Keyword.pop(opts, :name) do
      {nil, agent_opts} -> {[], agent_opts}
      {name, agent_opts} -> {[name: name], agent_opts}
    end
  end

  defp extract_genserver_opts(opts) when is_map(opts) do
    case Map.pop(opts, :name) do
      {nil, agent_opts} -> {[], agent_opts}
      {name, agent_opts} -> {[name: name], agent_opts}
    end
  end

  @doc """
  Returns a child_spec for supervision.
  """
  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = opts[:id] || __MODULE__

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Defaults.agent_server_shutdown_timeout_ms(),
      restart: :permanent,
      type: :worker
    }
  end

  @typedoc """
  Selector for `call/4` and `state/3`. Receives the full
  `%AgentServer.State{}`; the slice the user cares about lives at
  `state.agent.state` (or under the agent's declared `path/0`). Must
  return a tagged `{:ok, _}` or `{:error, _}` tuple.

  Selectors run synchronously in the agent process. A raising selector is
  caught and surfaces to the caller as
  `{:error, {:selector_raised, exception, stacktrace}}`.

  No `:skip` return — the caller is blocking, so "skip" has no meaning.
  Use `subscribe/4` for the ambient pattern that supports `:skip`.
  """
  @type call_selector :: (State.t() -> {:ok, term()} | {:error, term()})

  @typedoc """
  Selector for `subscribe/4`. Same calling convention as `call_selector/0`,
  with one extra return value: `:skip` keeps the subscription alive and
  delivers nothing to the subscriber.
  """
  @type subscribe_selector :: (State.t() -> {:ok, term()} | {:error, term()} | :skip)

  @doc """
  Synchronously sends a signal, runs the pipeline, and projects the
  post-pipeline state through `selector`.

  After the outermost middleware unwinds and the signal's directives
  execute, `selector` runs over `%AgentServer.State{}` and its tagged
  return is delivered to the caller. On chain error, the selector is
  **not** invoked — the chain's error is delivered verbatim per
  [ADR 0018](../../guides/adr/0018-tagged-tuple-return-shape.md) §3.

  Retry middleware that re-invokes `next` does not fire the selector
  multiple times — it fires once per outermost return.

  ## Options

  - `:timeout` — ms to wait (default `Defaults.agent_server_call_timeout_ms/0`)

  ## Returns

  - `{:ok, value}` / `{:error, reason}` — selector return passed through verbatim
  - `{:error, reason}` — chain error from the action / middleware (selector skipped)
  - `{:error, {:selector_raised, exception, stacktrace}}` — selector raised
  - `{:error, :not_found}` / `{:error, :invalid_server}` — server lookup failed
  - Exits with `{:noproc, ...}` / `{:timeout, ...}` if the agent dies or the
    GenServer.call times out

  ## Examples

      {:ok, counter} =
        AgentServer.call(pid, signal, fn s -> {:ok, s.agent.state.counter} end)

      {:ok, :done} =
        AgentServer.call(pid, signal, fn _s -> {:ok, :done} end, timeout: 10_000)
  """
  @spec call(server(), Signal.t(), call_selector(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(server, %Signal{} = signal, selector, opts \\ [])
      when is_function(selector, 1) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_call_timeout_ms())

    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:signal_with_selector, signal, selector}, timeout)
    end
  end

  @doc """
  Asynchronously sends a signal for processing.

  Returns immediately. The signal is processed in the background.

  ## Options

  Reserved for dispatch overrides, telemetry tags, and future knobs.
  Currently unused — adding it now means callers don't break when knobs
  land later.

  ## Returns

  * `:ok` - Signal queued successfully
  * `{:error, :not_found}` - Server not found via registry
  * `{:error, :invalid_server}` - Unsupported server reference

  ## Examples

      :ok = Jido.AgentServer.cast(pid, signal)
      :ok = Jido.AgentServer.cast(pid, signal, [])
  """
  @spec cast(server(), Signal.t(), keyword()) :: :ok | {:error, term()}
  def cast(server, %Signal{} = signal, opts \\ []) when is_list(opts) do
    with {:ok, pid} <- resolve_server(server) do
      _ = opts
      GenServer.cast(pid, {:signal, signal})
    end
  end

  @doc """
  Synchronously read a projection of the agent's `%State{}` without
  running the signal pipeline.

  `selector` runs over the current `%State{}` and its tagged return is
  delivered to the caller. No signal is processed — this is a pure read.

  Use this for liveness checks, bootstrap reads, or test inspection.
  Pod-level helpers like `Pod.fetch_state/1`, `Pod.fetch_topology/1`, and
  similar typed projections wrap this primitive with a baked-in selector.

  ## Options

  - `:timeout` — ms to wait (default `Defaults.agent_server_call_timeout_ms/0`)

  ## Returns

  - `{:ok, value}` / `{:error, reason}` — selector return passed through verbatim
  - `{:error, {:selector_raised, exception, stacktrace}}` — selector raised
  - `{:error, :not_found}` / `{:error, :invalid_server}` — server lookup failed

  ## Examples

      # Liveness check
      {:ok, :ok} = AgentServer.state(pid, fn _ -> {:ok, :ok} end)

      # Bootstrap / "what's my agent_id?"
      {:ok, id} = AgentServer.state(pid, fn s -> {:ok, s.id} end)

      # Test inspection
      {:ok, counter} =
        AgentServer.state(pid, fn s -> {:ok, s.agent.state.counter} end)
  """
  @spec state(server(), call_selector(), keyword()) :: {:ok, term()} | {:error, term()}
  def state(server, selector, opts \\ []) when is_function(selector, 1) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_call_timeout_ms())

    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:read_state_with_selector, selector}, timeout)
    end
  end

  @doc """
  Subscribe to signals matching `pattern`, with a selector deciding what
  the subscriber sees.

  The selector runs after the outermost middleware unwinds (same hook
  point as `call/4`). Returning `:skip` keeps the subscription silent and
  alive; `{:ok, _}` / `{:error, _}` dispatches the result to the
  subscriber. With `once: true`, the subscription is removed after the
  first non-`:skip` selector return.

  Patterns are compiled by `Jido.Signal.Router` and have identical
  semantics to `signal_routes/1` declarations: literals (`"work.start"`),
  single-segment wildcards (`"work.*"` matches any single segment after
  `"work."`), and the multi-segment wildcard (`"audit.**"`, or `"**"`
  alone to match every signal regardless of segment count).

  Default dispatch is `{:pid, target: self()}`, which sends
  `{:jido_subscription, sub_ref, %{signal_type: type, result: result}}`
  to the caller.

  ## Options

  - `:dispatch` — dispatch config (default `{:pid, target: self()}`)
  - `:once` — boolean, if true unsubscribe after first non-`:skip` fire (default `false`)

  ## Returns

  - `{:ok, sub_ref}` — subscription registered; pass `sub_ref` to `unsubscribe/2`
  - `{:error, reason}` — pattern invalid or server lookup failed
  """
  @spec subscribe(server(), String.t(), subscribe_selector(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def subscribe(server, pattern, selector, opts \\ [])
      when is_binary(pattern) and is_function(selector, 1) do
    dispatch = Keyword.get(opts, :dispatch, {:pid, target: self()})
    once? = Keyword.get(opts, :once, false)

    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:subscribe, pattern, selector, dispatch, self(), once?})
    end
  end

  @doc """
  Cancel a subscription created via `subscribe/4`.

  Idempotent — unknown refs are silently ignored.
  """
  @spec unsubscribe(server(), reference()) :: :ok | {:error, term()}
  def unsubscribe(server, sub_ref) when is_reference(sub_ref) do
    with {:ok, pid} <- resolve_server(server) do
      GenServer.cast(pid, {:unsubscribe, sub_ref})
    end
  end

  @doc """
  Block until the AgentServer has emitted `jido.agent.lifecycle.ready`.

  Useful when callers spawn an agent and need to assert that thaw +
  reconcile + plugin start has completed before sending signals or
  reading agent state. If the agent is already past `:idle` (ready
  fired before the call), replies immediately.

  ## Options

  - `:timeout` — ms to wait (default `Defaults.agent_server_await_timeout_ms/0`)

  ## Returns

  - `:ok` - Agent is ready
  - `{:error, :timeout}` - Did not become ready in `timeout` ms
  - `{:error, {:down, reason}}` - Agent process exited while waiting
  - `{:error, :not_found}` - Server reference did not resolve
  """
  @spec await_ready(server(), keyword()) ::
          :ok | {:error, :timeout | {:down, term()} | term()}
  def await_ready(server, opts \\ []) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_await_timeout_ms())

    case resolve_server(server) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        GenServer.cast(pid, {:register_ready_waiter, self(), ref})

        receive do
          {:jido_ready, ^ref} ->
            Process.demonitor(ref, [:flush])
            :ok

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:error, {:down, reason}}
        after
          timeout ->
            GenServer.cast(pid, {:cancel_ready_waiter, ref})
            Process.demonitor(ref, [:flush])
            {:error, :timeout}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Wait for a child with the given tag to be registered under the agent.

  Thin wrapper over `subscribe/4` with `once: true`. Fast-paths via
  `{:get_child_pid, tag}` when the child is already present; otherwise
  subscribes to `jido.agent.child.started` and resolves on the first
  matching selector hit.

  ## Options

  - `:timeout` - ms to wait before giving up (defaults to
    `Jido.Config.Defaults.agent_server_await_timeout_ms/0`)

  ## Returns

  - `{:ok, pid}` - Child registered (either already present or newly appeared)
  - `{:error, :timeout}` - Child did not appear in time
  - `{:error, :not_found}` - Parent server not found via resolution
  """
  @spec await_child(server(), term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def await_child(server, child_tag, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_await_timeout_ms())

    with {:ok, pid} <- resolve_server(server) do
      case GenServer.call(pid, {:get_child_pid, child_tag}) do
        {:ok, child_pid} ->
          {:ok, child_pid}

        :not_found ->
          selector = fn %State{} = state ->
            case State.get_child(state, child_tag) do
              %ChildInfo{pid: child_pid} when is_pid(child_pid) -> {:ok, child_pid}
              _ -> :skip
            end
          end

          case subscribe(pid, "jido.agent.child.started", selector, once: true) do
            {:ok, ref} ->
              # Re-check after subscribing — the natural `child.started`
              # cast can arrive between the initial `:get_child_pid` reply
              # and the `subscribe` call returning, in which case the
              # cascade already populated state.children but our
              # subscriber wasn't registered in time to observe it.
              case GenServer.call(pid, {:get_child_pid, child_tag}) do
                {:ok, child_pid} ->
                  unsubscribe(pid, ref)
                  {:ok, child_pid}

                :not_found ->
                  wait_for_child_subscription(pid, ref, timeout)
              end

            error ->
              error
          end
      end
    end
  end

  defp wait_for_child_subscription(server, ref, timeout) do
    receive do
      {:jido_subscription, ^ref, %{result: {:ok, value}}} -> {:ok, value}
      {:jido_subscription, ^ref, %{result: {:error, reason}}} -> {:error, reason}
    after
      timeout ->
        unsubscribe(server, ref)
        {:error, :timeout}
    end
  end

  @doc """
  Enables or disables debug mode at runtime.

  When debug mode is enabled, the agent records recent events in a ring buffer
  for diagnostic purposes.

  ## Examples

      :ok = AgentServer.set_debug(pid, true)
      # ... run some operations ...
      {:ok, events} = AgentServer.recent_events(pid)
  """
  @spec set_debug(server(), boolean()) :: :ok | {:error, term()}
  def set_debug(server, enabled) when is_boolean(enabled) do
    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:set_debug, enabled})
    end
  end

  @doc """
  Retrieves recent debug events from the agent's event buffer.

  Events are returned newest-first. Each event includes:
  - `:at` - Monotonic timestamp in milliseconds
  - `:type` - Event type atom (e.g., `:signal_received`, `:directive_started`)
  - `:data` - Event-specific data map

  Returns `{:error, :debug_not_enabled}` if debug mode is off.

  ## Options

  - `:limit` - Maximum number of events to return (default: all, max 50)

  ## Examples

      {:ok, events} = AgentServer.recent_events(pid, limit: 10)
  """
  @spec recent_events(server(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recent_events(server, opts \\ []) do
    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:recent_events, opts})
    end
  end

  @doc """
  Looks up an agent by ID in a specific registry.

  Returns the pid if found, nil otherwise.

  ## Examples

      pid = Jido.AgentServer.whereis(MyApp.Jido.Registry, "agent-123")
      # => #PID<0.123.0>
  """
  @spec whereis(module(), String.t()) :: pid() | nil
  def whereis(registry, id) when is_atom(registry) and is_binary(id) do
    whereis(registry, id, [])
  end

  @spec whereis(module(), String.t(), keyword()) :: pid() | nil
  def whereis(registry, id, opts)
      when is_atom(registry) and is_binary(id) and is_list(opts) do
    key = Jido.partition_key(id, Keyword.get(opts, :partition))

    case Registry.lookup(registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns a via tuple for Registry-based naming.

  ## Examples

      name = Jido.AgentServer.via_tuple("agent-id", MyApp.Jido.Registry)
      GenServer.call(name, :get_state)
  """
  @spec via_tuple(String.t(), module()) :: {:via, Registry, {module(), term()}}
  def via_tuple(id, registry) when is_binary(id) and is_atom(registry) do
    via_tuple(id, registry, [])
  end

  @spec via_tuple(String.t(), module(), keyword()) :: {:via, Registry, {module(), term()}}
  def via_tuple(id, registry, opts)
      when is_binary(id) and is_atom(registry) and is_list(opts) do
    {:via, Registry, {registry, Jido.partition_key(id, Keyword.get(opts, :partition))}}
  end

  @doc """
  Check if the agent server process is alive.
  """
  @spec alive?(server()) :: boolean()
  def alive?(server) when is_pid(server), do: Process.alive?(server)

  def alive?(server) do
    case resolve_server(server) do
      {:ok, pid} -> Process.alive?(pid)
      {:error, _} -> false
    end
  end

  @doc """
  Low-level primitive: imperatively attach a running agent to a parent ref.

  Used internally by the `%Jido.Agent.Directive.AdoptChild{}` executor to
  push the parent relationship into the child's live `state.parent`.
  Prefer booting the child with `parent: parent_ref` in its AgentServer
  options (`State.from_options/3` consumes it) so `post_init` can emit
  `jido.agent.child.started` declaratively — this function exists for
  the explicit-adoption-at-runtime path only.
  """
  @spec adopt_parent(server(), ParentRef.t()) ::
          {:ok, %{id: String.t(), agent_module: module(), partition: term() | nil}}
          | {:error, term()}
  def adopt_parent(server, %ParentRef{} = parent_ref) do
    with {:ok, pid} <- resolve_server(server) do
      try do
        GenServer.call(pid, {:adopt_parent, parent_ref})
      catch
        :exit, {:noproc, _} -> {:error, :not_found}
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    end
  end

  @doc """
  Imperative counterpart to `Jido.Agent.Directive.adopt_child/3`.

  Adopts a live child into this agent's logical child map. Updates both
  the child's live parent reference and the manager's tracked
  `state.children` map before returning.

  Prefer returning a `%Jido.Agent.Directive.AdoptChild{}` from an action
  when the initiator is already inside an agent — this function is for
  external callers (tests, supervisors, LiveView mounts) that need to
  attach children from outside the signal/directive pipeline.
  """
  @spec adopt_child(server(), pid() | String.t(), term(), map()) ::
          {:ok, pid()} | {:error, term()}
  def adopt_child(server, child, tag, meta \\ %{}) do
    with {:ok, pid} <- resolve_server(server) do
      try do
        GenServer.call(pid, {:adopt_child, child, tag, meta})
      catch
        :exit, {:noproc, _} -> {:error, :not_found}
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    end
  end

  @doc """
  Requests graceful termination of a tracked child agent.

  This is the runtime counterpart to `Directive.stop_child/2`.
  """
  @spec stop_child(server(), term(), term()) :: :ok | {:error, term()}
  def stop_child(server, tag, reason \\ :normal) do
    with {:ok, pid} <- resolve_server(server) do
      try do
        GenServer.call(pid, {:stop_child, tag, reason})
      catch
        :exit, {:noproc, _} -> {:error, :not_found}
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Attachment API (for Jido.Agent.InstanceManager integration)
  # ---------------------------------------------------------------------------

  @doc """
  Attaches a process to this agent, tracking it as an active consumer.

  When attached, the agent will not idle-timeout. The agent monitors the
  attached process and automatically detaches it on exit.

  Used by `Jido.Agent.InstanceManager` to track LiveView sockets, WebSocket handlers,
  or any process that needs the agent to stay alive.

  ## Examples

      {:ok, pid} = Jido.Agent.InstanceManager.get(:sessions, key)
      :ok = Jido.AgentServer.attach(pid)

      # With explicit owner
      :ok = Jido.AgentServer.attach(pid, socket_pid)
  """
  @spec attach(server(), pid()) :: :ok | {:error, term()}
  def attach(server, owner_pid \\ self()) do
    with {:ok, pid} <- resolve_server(server) do
      try do
        GenServer.call(pid, {:attach, owner_pid})
      catch
        :exit, {:noproc, _} -> {:error, :not_found}
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    end
  end

  @doc """
  Detaches a process from this agent.

  If this was the last attachment and `idle_timeout` is configured,
  the idle timer starts.

  Note: You don't need to call this explicitly if the attached process
  exits normally — the monitor will handle cleanup automatically.

  ## Examples

      :ok = Jido.AgentServer.detach(pid)
  """
  @spec detach(server(), pid()) :: :ok | {:error, term()}
  def detach(server, owner_pid \\ self()) do
    with {:ok, pid} <- resolve_server(server) do
      try do
        GenServer.call(pid, {:detach, owner_pid})
      catch
        :exit, {:noproc, _} -> {:error, :not_found}
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    end
  end

  @doc """
  Touches the agent to reset the idle timer.

  Use this for request-based activity tracking (e.g., HTTP requests)
  where you don't want to maintain a persistent attachment.

  ## Examples

      # In a controller
      {:ok, pid} = Jido.Agent.InstanceManager.get(:sessions, key)
      :ok = Jido.AgentServer.touch(pid)
  """
  @spec touch(server()) :: :ok | {:error, term()}
  def touch(server) do
    with {:ok, pid} <- resolve_server(server) do
      GenServer.cast(pid, :touch)
    end
  end

  @doc false
  @spec register_dynamic_cron_runtime(State.t(), term(), term(), term(), term()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def register_dynamic_cron_runtime(
        %State{} = state,
        logical_id,
        cron_expr,
        message,
        timezone
      ) do
    with :ok <- validate_dynamic_cron_input(cron_expr, timezone) do
      runtime_spec = CronRuntimeSpec.dynamic(cron_expr, message, timezone)
      register_runtime_cron_job(state, logical_id, runtime_spec)
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc false
  @spec start_runtime_cron_job(State.t(), term(), CronRuntimeSpec.t()) ::
          {:ok, pid()} | {:error, term()}
  def start_runtime_cron_job(%State{} = state, logical_id, %CronRuntimeSpec{} = runtime_spec) do
    agent_pid = self()
    signal = CronRuntimeSpec.build_signal(runtime_spec, state.id, logical_id)

    Jido.Scheduler.run_every(
      fn ->
        if Process.alive?(agent_pid) do
          _ = Jido.AgentServer.cast(agent_pid, signal)
        end

        :ok
      end,
      runtime_spec.cron_expression,
      timezone: runtime_spec.timezone
    )
  end

  @doc false
  @spec register_runtime_cron_job(State.t(), term(), CronRuntimeSpec.t()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def register_runtime_cron_job(%State{} = state, logical_id, %CronRuntimeSpec{} = runtime_spec) do
    case start_runtime_cron_job(state, logical_id, runtime_spec) do
      {:ok, pid} ->
        {:ok, track_cron_job(state, logical_id, pid, runtime_spec: runtime_spec)}

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to register #{runtime_cron_log_label(runtime_spec)} #{inspect(logical_id)}: #{inspect(reason)}"
        )

        {:error, reason, state}
    end
  end

  defp runtime_cron_log_label(%CronRuntimeSpec{kind: :dynamic}), do: "runtime cron job"
  defp runtime_cron_log_label(%CronRuntimeSpec{kind: :schedule}), do: "schedule"

  @doc false
  @spec track_cron_job(State.t(), term(), pid(), keyword()) :: State.t()
  def track_cron_job(%State{} = state, logical_id, pid, opts \\ []) when is_pid(pid) do
    runtime_spec = Keyword.get(opts, :runtime_spec)
    {_old_pid, state} = untrack_cron_job(state, logical_id, cancel?: true)
    monitor_ref = Process.monitor(pid)

    state =
      if is_struct(runtime_spec, CronRuntimeSpec) do
        %{state | cron_runtime_specs: Map.put(state.cron_runtime_specs, logical_id, runtime_spec)}
      else
        state
      end

    %{
      state
      | cron_jobs: Map.put(state.cron_jobs, logical_id, pid),
        cron_monitors: Map.put(state.cron_monitors, logical_id, monitor_ref),
        cron_monitor_refs: Map.put(state.cron_monitor_refs, monitor_ref, logical_id),
        cron_restart_attempts: Map.delete(state.cron_restart_attempts, logical_id)
    }
  end

  @doc false
  @spec untrack_cron_job(State.t(), term(), keyword()) :: {pid() | nil, State.t()}
  def untrack_cron_job(%State{} = state, logical_id, opts \\ []) do
    cancel? = Keyword.get(opts, :cancel?, false)
    drop_runtime_spec? = Keyword.get(opts, :drop_runtime_spec?, false)
    pid = Map.get(state.cron_jobs, logical_id)
    monitor_ref = Map.get(state.cron_monitors, logical_id)
    timer_ref = Map.get(state.cron_restart_timers, logical_id)

    if cancel? and is_pid(pid) and Process.alive?(pid) do
      Jido.Scheduler.cancel(pid)
    end

    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end

    if is_reference(timer_ref) do
      :erlang.cancel_timer(timer_ref)
    end

    new_state = %{
      state
      | cron_jobs: Map.delete(state.cron_jobs, logical_id),
        cron_monitors: Map.delete(state.cron_monitors, logical_id),
        cron_monitor_refs:
          if(is_reference(monitor_ref),
            do: Map.delete(state.cron_monitor_refs, monitor_ref),
            else: state.cron_monitor_refs
          ),
        cron_restart_attempts: Map.delete(state.cron_restart_attempts, logical_id),
        cron_restart_timers: Map.delete(state.cron_restart_timers, logical_id),
        cron_restart_timer_refs:
          if(is_reference(timer_ref),
            do: Map.delete(state.cron_restart_timer_refs, timer_ref),
            else: state.cron_restart_timer_refs
          ),
        cron_runtime_specs:
          if(drop_runtime_spec?,
            do: Map.delete(state.cron_runtime_specs, logical_id),
            else: state.cron_runtime_specs
          )
    }

    {pid, new_state}
  end

  @doc false
  @spec persist_cron_specs(State.t(), map()) :: :ok | {:error, term()}
  def persist_cron_specs(%State{} = state, cron_specs) when is_map(cron_specs) do
    lifecycle_mod = state.lifecycle.mod
    cron_specs = Jido.Scheduler.normalize_cron_specs(cron_specs)

    if function_exported?(lifecycle_mod, :persist_cron_specs, 2) do
      lifecycle_mod.persist_cron_specs(state, cron_specs)
    else
      :ok
    end
  end

  @doc false
  @spec emit_cron_telemetry_event(State.t(), atom(), map()) :: :ok
  def emit_cron_telemetry_event(%State{} = state, event, metadata \\ %{})
      when is_atom(event) and is_map(metadata) do
    emit_telemetry(
      [:jido, :agent_server, :cron, event],
      %{system_time: System.system_time()},
      Map.merge(
        %{
          agent_id: state.id,
          agent_module: state.agent_module,
          jido_instance: state.jido,
          jido_partition: state.partition
        },
        metadata
      )
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(raw_opts) do
    opts = if is_map(raw_opts), do: Map.to_list(raw_opts), else: raw_opts

    with {:ok, options} <- Options.new(opts),
         {:ok, options} <- hydrate_parent_from_runtime_store(options),
         agent_module = options.agent_module,
         chain = build_middleware_chain(agent_module, options),
         agent = build_agent(agent_module, options),
         {:ok, state} <-
           State.from_options(options, agent_module, agent, middleware_chain: chain),
         :ok <- maybe_register_global(options, state) do
      state = maybe_monitor_parent(state)

      # Build the signal router before we emit lifecycle signals. The
      # Persister middleware (if declared) blocks on thaw IO during the
      # starting signal and replaces ctx.agent with the rehydrated struct;
      # downstream state.agent reflects post-thaw state. Plugin children /
      # subscriptions / cron jobs still bring up in handle_continue/2.
      signal_router = SignalRouter.build(state)
      state = %{state | signal_router: signal_router}

      state = emit_through_chain(state, lifecycle_starting_signal(state))
      # Persister middleware may have thawed an agent with staged cron specs
      # in its state. Extract them onto state.cron_specs so the post_init
      # phase can register them.
      state = extract_thawed_cron_specs(state)
      state = emit_through_chain(state, partition_assigned_signal(state))

      {:ok, state, {:continue, :post_init}}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp build_agent(agent_module, %Options{id: id, initial_state: state}) do
    cond do
      function_exported?(agent_module, :new, 1) ->
        agent_module.new(id: id, state: state)

      function_exported?(agent_module, :new, 0) ->
        agent_module.new()

      true ->
        raise Jido.Error.validation_error(
                "agent module #{inspect(agent_module)} does not implement new/0 or new/1"
              )
    end
  end

  defp lifecycle_starting_signal(%State{} = state) do
    LifecycleStarting.new!(%{}, source: "/agent/#{state.id}")
    |> with_root_trace()
  end

  defp lifecycle_ready_signal(%State{} = state) do
    LifecycleReady.new!(%{}, source: "/agent/#{state.id}")
    |> with_root_trace()
  end

  defp lifecycle_stopping_signal(%State{} = state, reason) do
    LifecycleStopping.new!(%{reason: reason}, source: "/agent/#{state.id}")
    |> with_root_trace()
  end

  defp partition_assigned_signal(%State{} = state) do
    PartitionAssigned.new!(%{partition: state.partition}, source: "/agent/#{state.id}")
    |> with_root_trace()
  end

  defp with_root_trace(%Signal{} = signal) do
    case Trace.put(signal, Trace.new_root()) do
      {:ok, s} -> s
      {:error, _} -> signal
    end
  end

  defp maybe_register_global(%Options{register_global: false}, _state), do: :ok

  defp maybe_register_global(%Options{register_global: true}, state) do
    case Registry.register(state.registry, Jido.partition_key(state.id, state.partition), %{}) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def handle_continue(:post_init, state) do
    state = start_plugin_children(state)
    state = start_plugin_subscriptions(state)

    lifecycle_opts = [
      idle_timeout: state.lifecycle.idle_timeout,
      pool: state.lifecycle.pool,
      pool_key: state.lifecycle.pool_key
    ]

    state = state.lifecycle.mod.init(lifecycle_opts, state)

    state = register_plugin_schedules(state)
    state = register_restored_cron_specs(state)
    state = maybe_persist_parent_binding(state)

    notify_parent_of_startup(state)

    state = emit_through_chain(state, lifecycle_ready_signal(state))
    state = State.set_status(state, :idle)
    state = notify_ready_waiters(state)

    {:noreply, state}
  end

  @impl true
  def handle_call({:signal_with_selector, %Signal{} = signal, selector}, _from, state)
      when is_function(selector, 1) do
    {traced_signal, _ctx} = TraceContext.ensure_from_signal(signal)

    try do
      case process_signal(state, traced_signal) do
        {:ok, new_state, _directives} ->
          {:reply, invoke_call_selector(selector, new_state), new_state}

        {:error, committed_state, reason} ->
          # ADR 0018 §3: chain error short-circuits selector evaluation;
          # reason is delivered to the caller verbatim.
          {:reply, {:error, reason}, committed_state}

        {:stop, stop_reason, executed_state} ->
          # A directive returned :stop. Run the selector against the
          # post-directive state so the caller still gets a tagged tuple,
          # then stop after replying.
          reply = invoke_call_selector(selector, executed_state)
          {:stop, stop_reason, reply, State.set_status(executed_state, :stopping)}
      end
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        Logger.error(
          "Signal call failed for #{state.id}: #{inspect(kind)} #{inspect(reason)}\n" <>
            Exception.format_stacktrace(stacktrace)
        )

        # Return a clean error to the caller; agent stays alive.
        {:reply, {:error, reason}, state}
    after
      TraceContext.clear()
    end
  end

  def handle_call({:read_state_with_selector, selector}, _from, %State{} = state)
      when is_function(selector, 1) do
    # Pure read — no signal pipeline runs. Selector projects %State{}
    # to whatever the caller asked for. Wrap in try/rescue so a raising
    # selector doesn't crash the agent.
    {:reply, invoke_call_selector(selector, state), state}
  end

  def handle_call({:set_debug, enabled}, _from, %State{} = state) do
    new_state = State.set_debug(state, enabled)
    {:reply, :ok, new_state}
  end

  def handle_call({:recent_events, opts}, _from, %State{} = state) do
    if state.debug || Jido.Debug.enabled?(state.jido) do
      events = State.get_debug_events(state, opts)
      {:reply, {:ok, events}, state}
    else
      {:reply, {:error, :debug_not_enabled}, state}
    end
  end

  def handle_call({:get_child_pid, child_tag}, _from, %State{} = state) do
    case State.get_child(state, child_tag) do
      %ChildInfo{pid: pid} when is_pid(pid) -> {:reply, {:ok, pid}, state}
      _ -> {:reply, :not_found, state}
    end
  end

  def handle_call(
        {:subscribe, pattern, selector, dispatch, caller_pid, once?},
        _from,
        %State{} = state
      )
      when is_binary(pattern) and is_function(selector, 1) and is_pid(caller_pid) and
             is_boolean(once?) do
    case JidoRouter.Validator.validate_path(pattern) do
      {:ok, _} ->
        sub_ref = make_ref()
        monitor_ref = Process.monitor(caller_pid)

        entry = %{
          pattern_compiled: pattern,
          selector: selector,
          dispatch: dispatch,
          monitor_ref: monitor_ref,
          once: once?
        }

        {:reply, {:ok, sub_ref},
         %{state | signal_subscribers: Map.put(state.signal_subscribers, sub_ref, entry)}}

      {:error, reason} ->
        {:reply, {:error, {:invalid_pattern, reason}}, state}
    end
  end

  def handle_call({:attach, owner_pid}, _from, state) do
    case state.lifecycle.mod.handle_event({:attach, owner_pid}, state) do
      {:cont, new_state} -> {:reply, :ok, new_state}
      {:stop, reason, new_state} -> {:stop, reason, :ok, new_state}
    end
  end

  def handle_call({:detach, owner_pid}, _from, state) do
    case state.lifecycle.mod.handle_event({:detach, owner_pid}, state) do
      {:cont, new_state} -> {:reply, :ok, new_state}
      {:stop, reason, new_state} -> {:stop, reason, :ok, new_state}
    end
  end

  def handle_call({:adopt_parent, %ParentRef{} = parent_ref}, _from, %State{} = state) do
    cond do
      not is_nil(state.parent) ->
        {:reply, {:error, :already_attached}, state}

      not is_pid(parent_ref.pid) ->
        {:reply, {:error, :invalid_parent}, state}

      true ->
        case persist_parent_binding(state.jido, state.id, state.partition, parent_ref) do
          :ok ->
            new_state =
              state
              |> State.attach_parent(parent_ref)
              |> maybe_monitor_parent()
              |> State.record_debug_event(:parent_adopted, %{
                parent_id: parent_ref.id,
                tag: parent_ref.tag
              })

            # Runtime adoption converges on the same observable signal as
            # boot-time adoption (`handle_continue(:post_init, ...)`). This
            # lets plugins/signal_routes react to "a new child is now mine"
            # without needing a separate hook for `AdoptChild` directives.
            notify_parent_of_startup(new_state)

            {:reply,
             {:ok,
              %{
                id: new_state.id,
                agent_module: new_state.agent_module,
                partition: new_state.partition
              }}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:adopt_child, child, tag, meta}, _from, %State{} = state) do
    with :ok <- ensure_adopt_tag_available(state, tag),
         {:ok, child_pid} <- resolve_adopt_child(child, state),
         :ok <- ensure_adopt_not_self(child_pid),
         {:ok, child_runtime} <- perform_child_adoption(child_pid, tag, meta, state) do
      child_info =
        ChildInfo.new!(%{
          pid: child_pid,
          ref: Process.monitor(child_pid),
          module: child_runtime.agent_module,
          id: child_runtime.id,
          partition: child_runtime.partition,
          tag: tag,
          meta: meta
        })

      # Synthesize a `jido.agent.child.adopted` after the state mutation
      # so subscribers see the post-adoption state (per ADR 0021 §2: state
      # changes need a subscribable channel). `notify_parent_of_startup`
      # on the child side will also cast `jido.agent.child.started` back
      # to us asynchronously — that signal observes the same registration
      # but with a later, race-prone delivery; this synthesized signal is
      # the synchronous, parent-side announcement.
      signal =
        ChildAdopted.new!(
          %{
            tag: tag,
            pid: child_pid,
            child_id: child_runtime.id,
            child_module: child_runtime.agent_module,
            child_partition: child_runtime.partition,
            meta: meta || %{}
          },
          source: "/agent/#{state.id}"
        )

      new_state =
        state
        |> State.add_child(tag, child_info)
        |> State.record_debug_event(:child_adopted, %{child_id: child_runtime.id, tag: tag})
        |> then(&dispatch_synthetic_signal(signal, &1))

      {:reply, {:ok, child_pid}, new_state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_child, tag, reason}, _from, %State{} = state) do
    signal =
      Signal.new!(
        "jido.agent.stop_child",
        %{tag: tag, reason: reason},
        source: "/agent/#{state.id}"
      )

    :ok = StopChildRuntime.exec(tag, reason, signal, state)
    {:reply, :ok, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    case state.lifecycle.mod.handle_event(:touch, state) do
      {:cont, new_state} -> {:noreply, new_state}
      {:stop, reason, new_state} -> {:stop, reason, new_state}
    end
  end

  def handle_cast({:unsubscribe, sub_ref}, %State{} = state) when is_reference(sub_ref) do
    case Map.pop(state.signal_subscribers, sub_ref) do
      {nil, _} ->
        {:noreply, state}

      {%{monitor_ref: monitor_ref}, remaining} ->
        Process.demonitor(monitor_ref, [:flush])
        {:noreply, %{state | signal_subscribers: remaining}}
    end
  end

  def handle_cast({:register_ready_waiter, pid, ref}, %State{status: status} = state)
      when status in [:idle, :stopping] do
    # Already past lifecycle.ready; reply immediately and skip parking.
    send(pid, {:jido_ready, ref})
    {:noreply, state}
  end

  def handle_cast({:register_ready_waiter, pid, ref}, %State{} = state) do
    {:noreply, %{state | ready_waiters: Map.put(state.ready_waiters, ref, pid)}}
  end

  def handle_cast({:cancel_ready_waiter, ref}, %State{} = state) do
    {:noreply, %{state | ready_waiters: Map.delete(state.ready_waiters, ref)}}
  end

  def handle_cast({:signal, %Signal{} = signal}, state) do
    {traced_signal, _ctx} = TraceContext.ensure_from_signal(signal)

    try do
      case process_signal(state, traced_signal) do
        {:ok, new_state, _directives} -> {:noreply, new_state}
        {:error, committed_state, _reason} -> {:noreply, committed_state}
        {:stop, reason, new_state} -> {:stop, reason, State.set_status(new_state, :stopping)}
      end
    after
      TraceContext.clear()
    end
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled_signal, %Signal{} = signal}, state) do
    {traced_signal, _ctx} = TraceContext.ensure_from_signal(signal)

    try do
      case process_signal(state, traced_signal) do
        {:ok, new_state, _directives} -> {:noreply, new_state}
        {:error, committed_state, _reason} -> {:noreply, committed_state}
        {:stop, reason, new_state} -> {:stop, reason, State.set_status(new_state, :stopping)}
      end
    after
      TraceContext.clear()
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # First check if this is an attachment monitor
    case Map.get(state.lifecycle.attachment_monitors, ref) do
      ^pid ->
        # Attachment process died, delegate to lifecycle
        case state.lifecycle.mod.handle_event({:down, ref, pid}, state) do
          {:cont, state} -> {:noreply, state}
          {:stop, reason, state} -> {:stop, reason, state}
        end

      _ ->
        case Map.get(state.cron_monitor_refs, ref) do
          nil ->
            # Not an attachment, clean up any subscriber whose caller pid
            # died. The subscriber entry carries the caller's monitor_ref.
            state = drop_dead_subscriber(state, ref)

            if match?(%{parent: %ParentRef{pid: ^pid}}, state) do
              handle_parent_down(state, pid, reason)
            else
              handle_child_down(state, pid, reason)
            end

          logical_id ->
            {:noreply, handle_cron_job_down(state, logical_id, pid, reason)}
        end
    end
  end

  def handle_info({:timeout, ref, {:cron_restart, logical_id}}, state) do
    case Map.get(state.cron_restart_timer_refs, ref) do
      ^logical_id ->
        state = clear_cron_restart_timer(state, logical_id)

        case Map.get(state.cron_runtime_specs, logical_id) do
          %CronRuntimeSpec{} = runtime_spec ->
            case register_runtime_cron_job(state, logical_id, runtime_spec) do
              {:ok, new_state} ->
                emit_cron_telemetry_event(new_state, :restart_succeeded, %{
                  job_id: logical_id,
                  cron_expression: runtime_spec.cron_expression
                })

                # Synthesize a lifecycle signal and run it through the
                # agent's own pipeline so `subscribe/4` subscribers see
                # the post-restart state (per ADR 0021 §2: state changes
                # need a subscribable channel — no polling).
                new_pid = Map.fetch!(new_state.cron_jobs, logical_id)
                signal = cron_restarted_signal(new_state, logical_id, new_pid)
                new_state = dispatch_synthetic_signal(signal, new_state)

                {:noreply, new_state}

              {:error, reason, failed_state} ->
                {:noreply, schedule_cron_restart(failed_state, logical_id, reason)}
            end

          _ ->
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:timeout, ref, :lifecycle_idle_timeout}, state) do
    if state.lifecycle.idle_timer == ref do
      # Clear the timer so stale messages don't trigger after cancel/reset.
      state = %{state | lifecycle: %{state.lifecycle | idle_timer: nil}}

      case state.lifecycle.mod.handle_event(:idle_timeout, state) do
        {:cont, state} -> {:noreply, state}
        {:stop, reason, state} -> {:stop, reason, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:signal, %Signal{} = signal}, state) do
    {traced_signal, _ctx} = TraceContext.ensure_from_signal(signal)

    try do
      case process_signal(state, traced_signal) do
        {:ok, new_state, _directives} -> {:noreply, new_state}
        {:error, committed_state, _reason} -> {:noreply, committed_state}
        {:stop, reason, new_state} -> {:stop, reason, State.set_status(new_state, :stopping)}
      end
    after
      TraceContext.clear()
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Emit lifecycle.stopping at the top so middleware (notably
    # Jido.Middleware.Persister) can perform synchronous hibernate IO
    # before any other shutdown work runs.
    state =
      if clean_shutdown?(reason) do
        emit_through_chain(state, lifecycle_stopping_signal(state, reason))
      else
        state
      end

    state.lifecycle.mod.terminate(reason, state)

    # Clean up all cron jobs owned by this agent
    Enum.each(state.cron_jobs, fn {_job_id, pid} ->
      if is_pid(pid) and Process.alive?(pid) do
        Jido.Scheduler.cancel(pid)
      end
    end)

    :ok
  end

  defp clean_shutdown?(:normal), do: true
  defp clean_shutdown?(:shutdown), do: true
  defp clean_shutdown?({:shutdown, _}), do: true
  defp clean_shutdown?(_), do: false

  # ---------------------------------------------------------------------------
  # Internal: Signal Processing
  #
  # `process_signal/2` is shared between every signal entry point —
  # `handle_call({:signal_with_selector, ...})`, `handle_cast({:signal, ...})`,
  # `handle_info({:scheduled_signal, ...})`, and the lifecycle-signal
  # `emit_through_chain/2`. It runs the middleware chain, executes the
  # returned directives inline, and fires `subscribe/4` subscribers — then
  # hands back the committed state and the chain's tagged result.
  #
  # Uncaught raises propagate up; the `handle_call` handler catches them
  # and surfaces a clean `{:error, _}` reply, while cast/info handlers
  # let the GenServer crash so supervision can react. The Erlang mailbox
  # is the only queue; new incoming signals wait there until the current
  # handler returns.
  # ---------------------------------------------------------------------------

  @spec process_signal(State.t(), Signal.t()) ::
          {:ok, State.t(), [struct()]}
          | {:error, State.t(), term()}
          | {:stop, term(), State.t()}
  defp process_signal(%State{} = state, %Signal{} = signal) do
    start_time = System.monotonic_time()
    metadata = build_signal_metadata(state, signal)

    state =
      state
      |> State.record_debug_event(:signal_received, %{type: signal.type, id: signal.id})
      |> maybe_track_child_started(signal)
      |> maybe_track_cron_registered(signal)
      |> maybe_track_cron_cancelled(signal)

    emit_telemetry(
      [:jido, :agent_server, :signal, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = run_chain(signal, state)

      emit_telemetry(
        [:jido, :agent_server, :signal, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.merge(metadata, signal_stop_metadata_for(result))
      )

      case result do
        {:ok, new_state, directives} ->
          case execute_directives(directives, signal, new_state) do
            {:ok, executed_state} ->
              executed_state = fire_post_signal_hooks(executed_state, signal)
              {:ok, executed_state, directives}

            {:stop, reason, executed_state} ->
              # Subscribers are intentionally not fired on the stop branch
              # — the agent is going down; observers see the :DOWN monitor.
              {:stop, reason, executed_state}
          end

        {:error, new_state, reason} ->
          # Chain returned an error. `new_state` already has any
          # middleware-staged mutations committed; no directives to run on
          # this branch. Subscribers still fire per ADR 0018 §3.
          new_state = fire_post_signal_hooks(new_state, signal)
          {:error, new_state, reason}
      end
    catch
      kind, reason ->
        emit_telemetry(
          [:jido, :agent_server, :signal, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{kind: kind, error: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # Invokes a `call/4` / `state/3` selector in a try/rescue so a raising
  # selector doesn't crash the agent. Returns the selector's tagged tuple
  # on success or `{:error, {:selector_raised, exception, stacktrace}}` on
  # rescue.
  @spec invoke_call_selector(call_selector(), State.t()) ::
          {:ok, term()} | {:error, term()}
  defp invoke_call_selector(selector, %State{} = state) when is_function(selector, 1) do
    try do
      selector.(state)
    rescue
      exception -> {:error, {:selector_raised, exception, __STACKTRACE__}}
    end
  end

  # Middleware chain → routing → cmd/2. The outermost middleware wraps the
  # whole pipeline; the innermost `next` runs routing + cmd/2.
  #
  # The chain returns either branch with a fresh ctx; this function
  # commits ctx.agent to state.agent unconditionally so middleware-staged
  # state mutations (e.g. Persister's thaw) land regardless of whether
  # the action errored downstream. Action-level rollback already happened
  # inside cmd/2.
  #
  # See [ADR 0018](../../guides/adr/0018-tagged-tuple-return-shape.md).
  defp run_chain(%Signal{} = signal, %State{middleware_chain: chain} = state)
       when is_function(chain, 2) do
    ctx = build_signal_ctx(signal, state)

    case chain.(signal, ctx) do
      {:ok, new_ctx, directives} ->
        new_state = State.update_agent(state, new_ctx.agent)
        {:ok, new_state, List.wrap(directives)}

      {:error, new_ctx, reason} ->
        new_state = State.update_agent(state, new_ctx.agent)
        {:error, new_state, reason}
    end
  end

  # Routes a lifecycle / identity signal through the middleware chain.
  # Mirrors the agent-state sync in `run_chain/2` and runs any returned
  # directives inline so middleware-emitted side-effect signals (e.g.
  # `jido.persist.thaw.completed`) reach observers.
  #
  # Like the user-signal path, subscribers fire after the outermost
  # middleware unwinds and directives have executed.
  defp emit_through_chain(%State{} = state, %Signal{} = signal) do
    case run_chain(signal, state) do
      {:ok, new_state, directives} ->
        executed_state =
          case execute_directives(directives, signal, new_state) do
            {:ok, s} -> s
            {:stop, _reason, s} -> s
          end

        fire_post_signal_hooks(executed_state, signal)

      {:error, new_state, _reason} ->
        # state has middleware mutations committed; no directives to run on
        # the error branch. Fire subscribers against the updated state.
        fire_post_signal_hooks(new_state, signal)
    end
  end

  defp build_signal_ctx(%Signal{} = signal, %State{} = state) do
    signal_ctx = Jido.SignalCtx.ctx(signal)

    base = %{
      agent: state.agent,
      agent_module: state.agent_module,
      agent_id: state.id,
      partition: state.partition,
      parent: state.parent,
      orphaned_from: state.orphaned_from,
      jido: state.jido,
      cron_specs: state.cron_specs,
      __signal_router__: state.signal_router
    }

    Map.merge(base, signal_ctx)
  end

  @doc false
  # Inline directive loop. Each directive returns `:ok` (bounded I/O;
  # for async effects, spawn a task and emit a signal when done — see
  # the DirectiveExec docs). `{:stop, reason}` aborts the batch and
  # propagates as `{:stop, reason, state}` to the GenServer.
  #
  # The directive contract drops state from the return per ADR 0019 §6:
  # directives mutate no state, so there's no slot for a returned state
  # to land in. `state` threads through unchanged here; the cascade
  # callbacks invoked by `process_signal/2` are the only legal channel
  # for runtime-state writes that follow directive I/O.
  @spec execute_directives([struct()], Signal.t(), State.t()) ::
          {:ok, State.t()} | {:stop, term(), State.t()}
  def execute_directives(directives, signal, state)

  def execute_directives([], _signal, state), do: {:ok, state}

  def execute_directives([directive | rest], signal, state) do
    TraceContext.set_from_signal(signal)

    result =
      try do
        exec_directive_with_telemetry(directive, signal, state)
      after
        TraceContext.clear()
      end

    case result do
      :ok ->
        execute_directives(rest, signal, state)

      {:stop, reason} ->
        warn_if_normal_stop(reason, directive, state)
        {:stop, reason, state}
    end
  end

  defp build_signal_metadata(state, signal) do
    trace_metadata = TraceContext.to_telemetry_metadata()

    %{
      agent_id: state.id,
      agent_module: state.agent_module,
      signal_type: signal.type,
      jido_instance: state.jido,
      jido_partition: state.partition
    }
    |> Map.merge(trace_metadata)
  end

  defp signal_stop_metadata_for({:ok, _state, directives}) when is_list(directives) do
    %{
      directive_count: length(directives),
      directive_types: Formatter.summarize_directives(directives)
    }
  end

  defp signal_stop_metadata_for({:error, _state, reason}) do
    %{
      directive_count: 0,
      directive_types: %{},
      chain_error: reason
    }
  end

  defp maybe_track_child_started(
         %State{id: state_id} = state,
         %Signal{type: "jido.agent.child.started", data: data}
       )
       when is_map(data) do
    with %{
           parent_id: ^state_id,
           tag: tag,
           pid: pid,
           child_id: child_id,
           child_module: child_module
         } <-
           data,
         true <- is_pid(pid),
         true <- is_binary(child_id),
         true <- is_atom(child_module) do
      meta = Map.get(data, :meta, %{})
      child_partition = Map.get(data, :child_partition)

      case State.get_child(state, tag) do
        %ChildInfo{pid: ^pid} ->
          state

        %ChildInfo{ref: ref} ->
          Process.demonitor(ref, [:flush])
          track_child_started(state, pid, child_module, child_id, child_partition, tag, meta)

        nil ->
          track_child_started(state, pid, child_module, child_id, child_partition, tag, meta)
      end
    else
      _ -> state
    end
  end

  defp maybe_track_child_started(state, _signal), do: state

  defp track_child_started(state, pid, child_module, child_id, child_partition, tag, meta) do
    ref = Process.monitor(pid)

    child_info =
      ChildInfo.new!(%{
        pid: pid,
        ref: ref,
        module: child_module,
        id: child_id,
        partition: child_partition,
        tag: tag,
        meta: meta
      })

    State.add_child(state, tag, child_info)
  end

  # Cascade for `Jido.Agent.Directive.Cron`'s synthetic
  # `jido.agent.cron.registered` signal. The directive does all the I/O
  # (start the scheduler job, monitor it, persist the spec) and casts
  # this signal carrying the resulting pid + monitor_ref + spec; the
  # cascade is the sole writer of the runtime cron maps. Existing
  # entries under the same `job_id` are demonitored before being
  # overwritten so we don't leak monitor refs on upserts.
  defp maybe_track_cron_registered(
         %State{} = state,
         %Signal{type: "jido.agent.cron.registered", data: data}
       )
       when is_map(data) do
    case data do
      %{
        job_id: job_id,
        pid: pid,
        monitor_ref: monitor_ref,
        cron_spec: cron_spec,
        runtime_spec: runtime_spec
      }
      when is_pid(pid) and is_reference(monitor_ref) ->
        cleaned = drop_existing_cron_entry(state, job_id)

        %{
          cleaned
          | cron_specs: Map.put(cleaned.cron_specs, job_id, cron_spec),
            cron_runtime_specs: Map.put(cleaned.cron_runtime_specs, job_id, runtime_spec),
            cron_jobs: Map.put(cleaned.cron_jobs, job_id, pid),
            cron_monitors: Map.put(cleaned.cron_monitors, job_id, monitor_ref),
            cron_monitor_refs: Map.put(cleaned.cron_monitor_refs, monitor_ref, job_id),
            cron_restart_attempts: Map.delete(cleaned.cron_restart_attempts, job_id)
        }

      _ ->
        state
    end
  end

  defp maybe_track_cron_registered(state, _signal), do: state

  # Companion to `maybe_track_cron_registered/2`: drops the entry on
  # cancellation. Mirrors the I/O the directive already performed (the
  # scheduler job is cancelled and the monitor flushed before this
  # signal lands). Idempotent — a cancel for an unknown job_id is a
  # no-op.
  defp maybe_track_cron_cancelled(
         %State{} = state,
         %Signal{type: "jido.agent.cron.cancelled", data: %{job_id: job_id} = data}
       ) do
    monitor_ref = Map.get(data, :monitor_ref)

    %{
      state
      | cron_specs: Map.delete(state.cron_specs, job_id),
        cron_runtime_specs: Map.delete(state.cron_runtime_specs, job_id),
        cron_jobs: Map.delete(state.cron_jobs, job_id),
        cron_monitors: Map.delete(state.cron_monitors, job_id),
        cron_monitor_refs:
          if(is_reference(monitor_ref),
            do: Map.delete(state.cron_monitor_refs, monitor_ref),
            else: state.cron_monitor_refs
          ),
        cron_restart_attempts: Map.delete(state.cron_restart_attempts, job_id)
    }
  end

  defp maybe_track_cron_cancelled(state, _signal), do: state

  # Drop a stale cron entry under `job_id` before the cascade installs
  # the new pid+ref. Demonitors the previous entry's BEAM ref so we
  # don't leak monitors on `Cron` upserts.
  defp drop_existing_cron_entry(%State{} = state, job_id) do
    previous_ref = Map.get(state.cron_monitors, job_id)

    if is_reference(previous_ref) do
      Process.demonitor(previous_ref, [:flush])

      %{
        state
        | cron_monitor_refs: Map.delete(state.cron_monitor_refs, previous_ref),
          cron_jobs: Map.delete(state.cron_jobs, job_id),
          cron_monitors: Map.delete(state.cron_monitors, job_id)
      }
    else
      state
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: subscriber dispatch
  #
  # Subscribers fire after the outermost middleware unwinds and directives
  # have executed (the "post-signal" hook point). Per ADR 0018 §3, they
  # always run their selector against state, independent of the chain
  # outcome. The synchronous `call/4` path delivers its result directly
  # from `handle_call({:signal_with_selector, ...})` — there is no ack
  # table to fire alongside subscribers.
  # ---------------------------------------------------------------------------

  @spec fire_post_signal_hooks(State.t(), Signal.t()) :: State.t()
  defp fire_post_signal_hooks(%State{} = state, %Signal{} = signal) do
    fire_subscribers(state, signal)
  end

  defp fire_subscribers(%State{signal_subscribers: subs} = state, _signal)
       when map_size(subs) == 0 do
    state
  end

  defp fire_subscribers(%State{} = state, %Signal{type: type} = signal) do
    Enum.reduce(state.signal_subscribers, state, fn {sub_ref, entry}, acc_state ->
      if JidoRouter.matches?(type, entry.pattern_compiled) do
        case entry.selector.(acc_state) do
          :skip ->
            acc_state

          {:ok, _value} = fire ->
            dispatch_subscriber(entry.dispatch, sub_ref, signal, fire)
            if entry.once, do: remove_subscriber(acc_state, sub_ref), else: acc_state

          {:error, _reason} = fire ->
            dispatch_subscriber(entry.dispatch, sub_ref, signal, fire)
            if entry.once, do: remove_subscriber(acc_state, sub_ref), else: acc_state
        end
      else
        acc_state
      end
    end)
  end

  defp dispatch_subscriber({:pid, target: target}, sub_ref, %Signal{type: type}, result)
       when is_pid(target) do
    send(target, {:jido_subscription, sub_ref, %{signal_type: type, result: result}})
    :ok
  end

  defp dispatch_subscriber(dispatch, sub_ref, %Signal{type: type} = signal, result) do
    payload = %{signal_type: type, result: result, sub_ref: sub_ref, source_signal: signal}

    case Jido.Signal.new(%{
           type: "jido.subscription.fire",
           source: signal.source || "/agent/subscription",
           data: payload
         }) do
      {:ok, fire_signal} ->
        case Jido.Signal.Dispatch.dispatch(fire_signal, dispatch) do
          :ok -> :ok
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp remove_subscriber(%State{signal_subscribers: subs} = state, sub_ref) do
    case Map.pop(subs, sub_ref) do
      {nil, _} ->
        state

      {%{monitor_ref: monitor_ref}, remaining} ->
        Process.demonitor(monitor_ref, [:flush])
        %{state | signal_subscribers: remaining}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: Signal Routing
  # ---------------------------------------------------------------------------

  defp route_to_actions(router, signal) do
    case JidoRouter.route(router, signal) do
      {:ok, targets} when targets != [] ->
        actions = Enum.map(targets, &target_to_action(&1, signal))
        {:ok, actions}

      {:error, %{details: %{reason: :no_handlers_found}}} ->
        default_system_action(signal)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_system_action(%Signal{type: "jido.agent.stop", data: data}) do
    params = if is_map(data), do: data, else: %{}
    {:ok, [{Jido.Actions.Lifecycle.StopSelf, params}]}
  end

  defp default_system_action(_signal), do: {:error, :no_matching_route}

  defp target_to_action(mod, %Signal{data: data}) when is_atom(mod) do
    {mod, data}
  end

  defp target_to_action({mod, params}, _signal) when is_atom(mod) and is_map(params) do
    {mod, params}
  end

  # ---------------------------------------------------------------------------
  # Internal: Middleware Chain Composition
  # ---------------------------------------------------------------------------

  # Builds the on_signal/4 middleware chain for the agent at init time.
  # Order: agent's compile-time `middleware:` ++ runtime `Options.middleware:`
  # ++ plugin middleware halves (deferred to C5 — currently empty).
  #
  # Each entry is normalized to `{Mod, opts_map}` and wrapped around the core
  # next function in declaration order: the first entry becomes the outermost
  # wrap, the last entry the innermost. Duplicate-module detection is left
  # to user discretion — the chain runs whatever is declared, in order.
  defp build_middleware_chain(agent_module, %Options{middleware: runtime_mw}) do
    compile_mw =
      if function_exported?(agent_module, :middleware, 0),
        do: agent_module.middleware(),
        else: []

    plugin_halves = plugin_middleware_halves(agent_module)
    all_entries = compile_mw ++ runtime_mw ++ plugin_halves

    compose_chain(all_entries, &core_next/2)
  end

  # Plugin middleware halves are wired in C5 when `Jido.Plugin` is rewritten
  # on top of `use Jido.Slice + use Jido.Middleware`. C4 ships the chain
  # infrastructure with this hook returning [].
  defp plugin_middleware_halves(_agent_module), do: []

  defp normalize_entry({mod, opts}) when is_atom(mod) and is_map(opts), do: {mod, opts}
  defp normalize_entry(mod) when is_atom(mod), do: {mod, %{}}

  defp compose_chain(entries, core_next) do
    Enum.reduce(Enum.reverse(entries), core_next, fn entry, acc_next ->
      {mod, opts} = normalize_entry(entry)
      fn sig, ctx -> mod.on_signal(sig, ctx, opts, acc_next) end
    end)
  end

  # Innermost continuation: routing → cmd/2.
  #
  # Returns the tagged tuple per [ADR 0018](../../guides/adr/0018-tagged-tuple-return-shape.md):
  #   - `{:ok, ctx, dirs}` on chain success
  #   - `{:error, ctx, reason}` on routing failure or `cmd/2` error
  #
  # The error tuple carries `ctx` so middleware-staged state mutations
  # (`Persister`'s thaw, etc.) commit to `state.agent` regardless. cmd/2
  # is the action boundary: rollback semantics live there — on action
  # error, `cmd/2` returns the input agent unchanged, which is exactly
  # `ctx.agent` at this layer (containing prior middleware mutations).
  #
  # `%Directive.Error{}` is no longer manufactured by the cmd reducer or
  # by routing failures. User code is free to emit one on the success
  # path for log/audit purposes.
  defp core_next(%Signal{} = signal, ctx) do
    %{agent_module: agent_module, agent: agent, __signal_router__: router} = ctx

    case route_to_actions(router, signal) do
      {:ok, actions} ->
        action_arg =
          case actions do
            [single] -> single
            list when is_list(list) -> list
            other -> other
          end

        case agent_module.cmd(agent, action_arg, ctx: ctx, input_signal: signal) do
          {:ok, new_agent, directives} ->
            {:ok, Map.put(ctx, :agent, new_agent), List.wrap(directives)}

          {:error, reason} ->
            # Action errored; cmd/2 returned the input agent unchanged.
            # ctx.agent is still that input agent + middleware mutations,
            # which run_chain will commit to state.
            {:error, ctx, reason}
        end

      {:error, reason} ->
        routing_error =
          Jido.Error.routing_error("No route for signal #{inspect(signal.type)}", %{
            signal_type: signal.type,
            reason: reason
          })

        log_routing_error(ctx, routing_error)
        {:error, ctx, routing_error}
    end
  end

  # Concrete routing failures (invalid pattern, missing route, ...)
  # previously emitted a `%Directive.Error{}` that `DirectiveExec.Error`
  # logged on its success-path execution. The chain now short-circuits
  # before directives run, so log inline to preserve the operator-visible
  # signal.
  defp log_routing_error(ctx, %{message: message}) do
    Logger.debug("Agent #{Map.get(ctx, :agent_id, "unknown")} [routing]: #{message}")
  end

  # ---------------------------------------------------------------------------
  # Internal: Plugin Children
  # ---------------------------------------------------------------------------

  @doc false
  defp start_plugin_children(%State{} = state) do
    agent_module = state.agent_module

    plugin_specs =
      if function_exported?(agent_module, :plugin_specs, 0),
        do: agent_module.plugin_specs(),
        else: []

    Enum.reduce(plugin_specs, state, fn spec, acc_state ->
      config = spec.config || %{}
      start_plugin_spec_children(acc_state, spec.module, config)
    end)
  end

  defp start_plugin_spec_children(state, plugin_module, config) do
    if function_exported?(plugin_module, :child_spec, 1) do
      do_start_plugin_spec_children(state, plugin_module, config)
    else
      state
    end
  end

  defp do_start_plugin_spec_children(state, plugin_module, config) do
    case plugin_module.child_spec(config) do
      nil ->
        state

      %{} = child_spec ->
        start_plugin_child(state, plugin_module, child_spec)

      list when is_list(list) ->
        Enum.reduce(list, state, fn cs, s ->
          start_plugin_child(s, plugin_module, cs)
        end)

      other ->
        Logger.warning(
          "Invalid child_spec from plugin #{inspect(plugin_module)}: #{inspect(other)}"
        )

        state
    end
  end

  defp start_plugin_child(%State{} = state, plugin_module, %{start: {m, f, a}} = spec) do
    case apply(m, f, a) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        tag = {:plugin, plugin_module, spec[:id] || m}

        child_info =
          ChildInfo.new!(%{
            pid: pid,
            ref: ref,
            module: plugin_module,
            id: "#{plugin_module}-#{inspect(pid)}",
            tag: tag,
            meta: %{child_spec_id: spec[:id]}
          })

        new_children = Map.put(state.children, tag, child_info)
        %{state | children: new_children}

      {:error, reason} ->
        Logger.error("Failed to start plugin child #{inspect(plugin_module)}: #{inspect(reason)}")

        state
    end
  end

  defp start_plugin_child(%State{} = state, plugin_module, spec) do
    Logger.warning(
      "Plugin child_spec missing :start key for #{inspect(plugin_module)}: #{inspect(spec)}"
    )

    state
  end

  # ---------------------------------------------------------------------------
  # Internal: Plugin Subscriptions
  # ---------------------------------------------------------------------------

  @doc false
  defp start_plugin_subscriptions(%State{} = state) do
    agent_module = state.agent_module

    plugin_specs =
      if function_exported?(agent_module, :plugin_specs, 0),
        do: agent_module.plugin_specs(),
        else: []

    Enum.reduce(plugin_specs, state, fn spec, acc_state ->
      context = %{
        agent_ref: via_tuple(acc_state.id, acc_state.registry, partition: acc_state.partition),
        agent_id: acc_state.id,
        agent_module: agent_module,
        plugin_spec: spec,
        jido_instance: acc_state.jido,
        partition: acc_state.partition
      }

      config = spec.config || %{}

      subscriptions =
        cond do
          function_exported?(spec.module, :subscriptions, 2) ->
            spec.module.subscriptions(config, context)

          function_exported?(spec.module, :subscriptions, 0) ->
            spec.module.subscriptions()

          true ->
            []
        end

      Enum.reduce(subscriptions, acc_state, fn {sensor_module, sensor_config}, inner_state ->
        start_subscription_sensor(inner_state, spec.module, sensor_module, sensor_config, context)
      end)
    end)
  end

  defp start_subscription_sensor(
         %State{} = state,
         plugin_module,
         sensor_module,
         sensor_config,
         context
       ) do
    opts = [
      sensor: sensor_module,
      config: sensor_config,
      context: context
    ]

    case SensorRuntime.start_link(opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        tag = {:sensor, plugin_module, sensor_module}

        child_info =
          ChildInfo.new!(%{
            pid: pid,
            ref: ref,
            module: sensor_module,
            id: "#{plugin_module}-#{sensor_module}-#{inspect(pid)}",
            tag: tag,
            meta: %{plugin: plugin_module, sensor: sensor_module}
          })

        new_children = Map.put(state.children, tag, child_info)
        %{state | children: new_children}

      {:error, reason} ->
        Logger.warning(
          "Failed to start subscription sensor #{inspect(sensor_module)} for plugin #{inspect(plugin_module)}: #{inspect(reason)}"
        )

        state
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: Plugin Schedules
  # ---------------------------------------------------------------------------

  @doc false
  defp register_plugin_schedules(%State{skip_schedules: true} = state) do
    Logger.debug("AgentServer #{state.id} skipping plugin schedules")
    state
  end

  defp register_plugin_schedules(%State{} = state) do
    agent_module = state.agent_module

    schedules =
      if function_exported?(agent_module, :plugin_schedules, 0),
        do: agent_module.plugin_schedules(),
        else: []

    Enum.reduce(schedules, state, fn schedule_spec, acc_state ->
      register_schedule(acc_state, schedule_spec)
    end)
  end

  # Pulls staged cron specs (from a thawed agent's state) up onto state.cron_specs
  # and classifies them. Invalid specs are logged and dropped.
  defp extract_thawed_cron_specs(%State{agent: agent} = state) do
    {cleaned_agent, staged} = Jido.Scheduler.extract_staged_cron_specs(agent)

    case staged do
      empty when empty == %{} or empty == nil ->
        state

      staged ->
        {valid, invalid} = Jido.Scheduler.classify_cron_specs(staged)

        Enum.each(invalid, fn {job_id, spec, reason} ->
          require Logger

          Logger.error(
            "AgentServer #{state.id} dropped malformed persisted cron spec #{inspect(job_id)}: #{inspect(spec)} (#{inspect(reason)})"
          )
        end)

        merged = Map.merge(state.cron_specs, valid)
        %{state | agent: cleaned_agent, cron_specs: merged}
    end
  end

  defp register_restored_cron_specs(%State{cron_specs: cron_specs} = state)
       when map_size(cron_specs) == 0,
       do: state

  defp register_restored_cron_specs(%State{} = state) do
    Enum.reduce(state.cron_specs, state, fn {job_id, spec}, acc_state ->
      register_restored_cron_spec(acc_state, job_id, spec)
    end)
  end

  defp register_restored_cron_spec(
         %State{} = state,
         job_id,
         %{cron_expression: cron_expr, message: message, timezone: timezone}
       ) do
    if Map.has_key?(state.cron_jobs, job_id) do
      Logger.warning(
        "AgentServer #{state.id} skipping restored cron job #{inspect(job_id)} because declarative/plugin schedule already exists"
      )

      new_cron_specs = Map.delete(state.cron_specs, job_id)
      cleaned_state = %{state | cron_specs: new_cron_specs}

      case persist_cron_specs(cleaned_state, new_cron_specs) do
        :ok ->
          cleaned_state

        {:error, reason} ->
          emit_cron_telemetry_event(cleaned_state, :persist_failure, %{
            job_id: job_id,
            reason: reason
          })

          cleaned_state
      end
    else
      register_restored_cron_runtime(state, job_id, cron_expr, message, timezone)
    end
  end

  defp register_restored_cron_spec(%State{} = state, job_id, invalid_spec) do
    Logger.error(
      "AgentServer #{state.id} skipped invalid persisted cron spec #{inspect(job_id)}: #{inspect(invalid_spec)}"
    )

    state
  end

  # GenServer-context helper that restores a persisted cron spec by
  # spawning the scheduler job and installing the runtime maps directly
  # (no synthetic-signal cascade). Used only by the post-init restore
  # path. Mirrors the directive's `register_io/5` flow without the
  # cascade dispatch — directives go through `maybe_track_cron_registered/2`,
  # but a still-initializing GenServer can't rely on signal mailbox
  # turns yet. On failure we drop the persisted spec so a broken entry
  # doesn't block boot.
  defp register_restored_cron_runtime(state, job_id, cron_expr, message, timezone) do
    case Directive.Cron.register_io(state, cron_expr, message, job_id, timezone) do
      {:ok, io_result} ->
        commit_cron_io_result(state, io_result, cron_expr)

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to register cron job #{inspect(job_id)}: #{inspect(reason)}"
        )

        {_pid, runtime_state} =
          untrack_cron_job(state, job_id, cancel?: true, drop_runtime_spec?: true)

        %{runtime_state | cron_specs: Map.delete(runtime_state.cron_specs, job_id)}
    end
  end

  defp commit_cron_io_result(%State{} = state, io_result, cron_expr) do
    %{
      job_id: job_id,
      pid: pid,
      monitor_ref: monitor_ref,
      cron_spec: cron_spec,
      runtime_spec: runtime_spec
    } = io_result

    committed = %{
      state
      | cron_specs: Map.put(state.cron_specs, job_id, cron_spec),
        cron_runtime_specs: Map.put(state.cron_runtime_specs, job_id, runtime_spec),
        cron_jobs: Map.put(state.cron_jobs, job_id, pid),
        cron_monitors: Map.put(state.cron_monitors, job_id, monitor_ref),
        cron_monitor_refs: Map.put(state.cron_monitor_refs, monitor_ref, job_id),
        cron_restart_attempts: Map.delete(state.cron_restart_attempts, job_id)
    }

    Logger.debug(
      "AgentServer #{state.id} registered cron job #{inspect(job_id)}: #{cron_expr}"
    )

    emit_cron_telemetry_event(committed, :register, %{
      job_id: job_id,
      cron_expression: cron_expr
    })

    committed
  end

  defp register_schedule(%State{} = state, schedule_spec) do
    %{
      cron_expression: cron_expr,
      action: _action,
      job_id: job_id,
      signal_type: signal_type,
      timezone: timezone
    } = schedule_spec

    runtime_spec = CronRuntimeSpec.schedule(cron_expr, signal_type, timezone)

    case register_runtime_cron_job(state, job_id, runtime_spec) do
      {:ok, new_state} ->
        Logger.debug(
          "AgentServer #{state.id} registered schedule #{inspect(job_id)}: #{cron_expr}"
        )

        new_state

      {:error, _reason, failed_state} ->
        failed_state
    end
  end

  defp validate_dynamic_cron_input(cron_expr, _timezone)
       when not is_binary(cron_expr),
       do: {:error, :invalid_cron_expression}

  defp validate_dynamic_cron_input(_cron_expr, timezone)
       when not (is_nil(timezone) or is_binary(timezone)),
       do: {:error, :invalid_timezone}

  defp validate_dynamic_cron_input(_cron_expr, _timezone), do: :ok

  defp handle_cron_job_down(state, logical_id, pid, reason) do
    {tracked_pid, state} = untrack_cron_job(state, logical_id, cancel?: false)

    if tracked_pid == pid do
      # Emit before scheduling restart so subscribers see the death
      # announcement on a state where `cron_jobs[logical_id]` is already
      # removed. A `jido.agent.cron.restarted` follows when the restart
      # timer succeeds (only for abnormal exits).
      state = dispatch_synthetic_signal(cron_died_signal(state, logical_id, pid, reason), state)

      if normal_cron_exit?(reason) do
        state
      else
        schedule_cron_restart(state, logical_id, reason)
      end
    else
      state
    end
  end

  defp cron_died_signal(%State{} = state, logical_id, pid, reason) do
    CronDied.new!(
      %{job_id: logical_id, pid: pid, reason: reason},
      source: "/agent/#{state.id}/cron"
    )
  end

  defp cron_restarted_signal(%State{} = state, logical_id, pid) do
    CronRestarted.new!(
      %{job_id: logical_id, pid: pid},
      source: "/agent/#{state.id}/cron"
    )
  end

  defp schedule_cron_restart(state, logical_id, reason) do
    if Map.has_key?(state.cron_runtime_specs, logical_id) do
      attempt = Map.get(state.cron_restart_attempts, logical_id, 0)

      delay =
        min((@cron_restart_base_ms * :math.pow(2, attempt)) |> trunc(), @cron_restart_max_ms)

      timer_ref = :erlang.start_timer(delay, self(), {:cron_restart, logical_id})

      Logger.warning(
        "AgentServer #{state.id} scheduling cron restart for #{inspect(logical_id)} in #{delay}ms after #{inspect(reason)}"
      )

      emit_cron_telemetry_event(state, :restart_scheduled, %{
        job_id: logical_id,
        reason: reason,
        delay_ms: delay
      })

      %{
        state
        | cron_restart_attempts: Map.put(state.cron_restart_attempts, logical_id, attempt + 1),
          cron_restart_timers: Map.put(state.cron_restart_timers, logical_id, timer_ref),
          cron_restart_timer_refs: Map.put(state.cron_restart_timer_refs, timer_ref, logical_id)
      }
    else
      state
    end
  end

  defp clear_cron_restart_timer(state, logical_id) do
    case Map.pop(state.cron_restart_timers, logical_id) do
      {timer_ref, timers} when is_reference(timer_ref) ->
        %{
          state
          | cron_restart_timers: timers,
            cron_restart_timer_refs: Map.delete(state.cron_restart_timer_refs, timer_ref)
        }

      {_other, timers} ->
        %{state | cron_restart_timers: timers}
    end
  end

  defp normal_cron_exit?(:normal), do: true
  defp normal_cron_exit?(:shutdown), do: true
  defp normal_cron_exit?({:shutdown, _}), do: true
  defp normal_cron_exit?(_), do: false

  # ---------------------------------------------------------------------------
  # Internal: Lifecycle waiters
  # ---------------------------------------------------------------------------

  defp notify_ready_waiters(%State{ready_waiters: waiters} = state)
       when map_size(waiters) == 0,
       do: state

  defp notify_ready_waiters(%State{ready_waiters: waiters} = state) do
    Enum.each(waiters, fn {ref, pid} -> send(pid, {:jido_ready, ref}) end)
    %{state | ready_waiters: %{}}
  end

  defp drop_dead_subscriber(%State{signal_subscribers: subs} = state, monitor_ref) do
    case Enum.find(subs, fn {_ref, %{monitor_ref: ref}} -> ref == monitor_ref end) do
      {sub_ref, _entry} ->
        %{state | signal_subscribers: Map.delete(subs, sub_ref)}

      nil ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Server Resolution
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a server reference to a pid.

  Accepts the same reference types as `cast/3` and `call/4` — a pid, a
  registered atom, or a `{:via, ...}` tuple. Returns `{:error, :not_found}`
  when a registered name doesn't currently point at a process; does not
  check process liveness for direct pids (`is_pid/1` alone is enough to
  succeed).
  """
  @spec resolve(server()) :: {:ok, pid()} | {:error, term()}
  def resolve(server), do: resolve_server(server)

  defp resolve_server(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve_server({:via, _, _} = via) do
    case GenServer.whereis(via) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(name) when is_atom(name) do
    case GenServer.whereis(name) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(id) when is_binary(id) do
    # String IDs require explicit registry lookup via Jido.whereis/2
    {:error,
     {:invalid_server,
      "String IDs require explicit registry lookup. Use Jido.whereis(MyApp.Jido, \"#{id}\", partition: ...) first or pass the pid directly."}}
  end

  defp resolve_server(_), do: {:error, :invalid_server}

  # ---------------------------------------------------------------------------
  # Internal: Hierarchy
  # ---------------------------------------------------------------------------

  defp ensure_adopt_tag_available(state, tag) do
    case State.get_child(state, tag) do
      nil -> :ok
      _child -> {:error, {:tag_in_use, tag}}
    end
  end

  defp resolve_adopt_child(pid, _state) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :child_not_alive}
  end

  defp resolve_adopt_child(id, state) when is_binary(id) do
    case Jido.whereis(state.jido, id, partition: state.partition) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :child_not_found}
    end
  end

  defp resolve_adopt_child(child, _state), do: {:error, {:invalid_child, child}}

  defp ensure_adopt_not_self(pid) when pid == self(), do: {:error, :cannot_adopt_self}
  defp ensure_adopt_not_self(_pid), do: :ok

  defp perform_child_adoption(child_pid, tag, meta, state) do
    parent_ref =
      ParentRef.new!(%{
        pid: self(),
        id: state.id,
        partition: state.partition,
        tag: tag,
        meta: meta
      })

    adopt_parent(child_pid, parent_ref)
  end

  defp maybe_monitor_parent(%State{parent: %ParentRef{pid: pid}} = state) when is_pid(pid) do
    Process.monitor(pid)
    state
  end

  defp maybe_monitor_parent(state), do: state

  defp notify_parent_of_startup(%State{parent: %ParentRef{} = parent} = state)
       when is_pid(parent.pid) do
    child_started =
      ChildStarted.new!(
        %{
          parent_id: parent.id,
          child_id: state.id,
          child_partition: state.partition,
          child_module: state.agent_module,
          tag: parent.tag,
          pid: self(),
          meta: parent.meta || %{}
        },
        source: "/agent/#{state.id}"
      )

    traced_child_started =
      case Trace.put(child_started, Trace.new_root()) do
        {:ok, s} -> s
        {:error, _} -> child_started
      end

    _ = cast(parent.pid, traced_child_started)
    :ok
  end

  defp notify_parent_of_startup(_state), do: :ok

  defp handle_parent_down(
         %State{on_parent_death: :stop, parent: former_parent} = state,
         _pid,
         reason
       ) do
    _ = clear_parent_binding(state.jido, state.id, state.partition)
    state = emit_parent_died(state, former_parent, reason)
    stop_reason = wrap_parent_down_reason(reason)

    Logger.info(
      "AgentServer #{state.id} stopping: parent died (#{inspect(reason)}), wrapped stop_reason: #{inspect(stop_reason)}"
    )

    {:stop, stop_reason, State.set_status(state, :stopping)}
  end

  defp handle_parent_down(%State{on_parent_death: :continue} = state, _pid, reason) do
    {former_parent, orphaned_state} = transition_to_orphan(state, reason)
    orphaned_state = emit_parent_died(orphaned_state, former_parent, reason)

    Logger.info(
      "AgentServer #{state.id} continuing as orphan after parent #{former_parent.id} died (#{inspect(reason)})"
    )

    {:noreply, orphaned_state}
  end

  defp handle_parent_down(%State{on_parent_death: :emit_orphan} = state, _pid, reason) do
    {former_parent, orphaned_state} = transition_to_orphan(state, reason)
    orphaned_state = emit_parent_died(orphaned_state, former_parent, reason)
    orphaned_state = emit_identity_orphaned(orphaned_state, former_parent, reason)

    signal =
      Orphaned.new!(
        %{
          parent_id: former_parent.id,
          parent_pid: former_parent.pid,
          tag: former_parent.tag,
          meta: former_parent.meta || %{},
          reason: reason
        },
        source: "/agent/#{orphaned_state.id}"
      )

    traced_signal =
      case Trace.put(signal, Trace.new_root()) do
        {:ok, s} -> s
        {:error, _} -> signal
      end

    case process_signal(orphaned_state, traced_signal) do
      {:ok, new_state, _directives} -> {:noreply, new_state}
      {:error, committed_state, _reason} -> {:noreply, committed_state}
      {:stop, reason, new_state} -> {:stop, reason, State.set_status(new_state, :stopping)}
    end
  end

  defp emit_parent_died(%State{} = state, %ParentRef{} = former_parent, reason) do
    signal =
      ParentDied.new!(
        %{former_parent: former_parent, reason: reason},
        source: "/agent/#{state.id}"
      )

    dispatch_synthetic_signal(signal, state)
  end

  defp emit_parent_died(%State{} = state, _former_parent, _reason), do: state

  defp emit_identity_orphaned(%State{} = state, %ParentRef{} = former_parent, reason) do
    signal =
      IdentityOrphaned.new!(
        %{former_parent: former_parent, reason: reason},
        source: "/agent/#{state.id}"
      )

    dispatch_synthetic_signal(signal, state)
  end

  defp emit_identity_orphaned(%State{} = state, _former_parent, _reason), do: state

  # Synthesize a signal locally and run it through the agent's own
  # `process_signal/2` pipeline so subscribers see it. Used by handlers
  # that mutate state outside the signal pipeline (DOWN handlers,
  # restart timers, adoption handlers) to give `subscribe/4` consumers
  # a subscribable channel for state-only transitions per ADR 0021 §2.
  #
  # Returns the post-pipeline `%State{}`. The caller composes it into
  # whatever return shape the surrounding handler needs (`{:noreply, _}`,
  # `{:reply, _, _}`, etc.). `:stop` directives from middleware are
  # collapsed to a state return — synthetic signals shouldn't terminate
  # the agent on their own.
  defp dispatch_synthetic_signal(signal, %State{} = state) do
    traced_signal =
      case Trace.put(signal, Trace.new_root()) do
        {:ok, s} -> s
        {:error, _} -> signal
      end

    case process_signal(state, traced_signal) do
      {:ok, new_state, _directives} -> new_state
      {:error, committed_state, _reason} -> committed_state
      {:stop, _reason, new_state} -> new_state
    end
  end

  defp handle_child_down(%State{} = state, pid, reason) do
    {tag, state} = State.remove_child_by_pid(state, pid)

    if tag do
      Logger.debug("AgentServer #{state.id} child #{inspect(tag)} exited: #{inspect(reason)}")

      signal =
        ChildExit.new!(
          %{tag: tag, pid: pid, reason: reason},
          source: "/agent/#{state.id}"
        )

      traced_signal =
        case Trace.put(signal, Trace.new_root()) do
          {:ok, s} -> s
          {:error, _} -> signal
        end

      case process_signal(state, traced_signal) do
        {:ok, new_state, _directives} -> {:noreply, new_state}
        {:error, committed_state, _reason} -> {:noreply, committed_state}
        {:stop, reason, new_state} -> {:stop, reason, State.set_status(new_state, :stopping)}
      end
    else
      {:noreply, state}
    end
  end

  # Wraps parent-down reasons so OTP treats them as clean shutdowns.
  # OTP only considers :normal, :shutdown, and {:shutdown, term} as "normal" exits.
  # All other reasons get logged as errors by the default GenServer logger.
  defp wrap_parent_down_reason(:normal), do: {:shutdown, {:parent_down, :normal}}
  defp wrap_parent_down_reason(:noproc), do: {:shutdown, {:parent_down, :noproc}}
  defp wrap_parent_down_reason(:shutdown), do: {:shutdown, {:parent_down, :shutdown}}
  defp wrap_parent_down_reason({:shutdown, _} = r), do: {:shutdown, {:parent_down, r}}
  defp wrap_parent_down_reason(reason), do: {:shutdown, {:parent_down, reason}}

  defp transition_to_orphan(%State{parent: %ParentRef{} = former_parent} = state, reason) do
    _ = clear_parent_binding(state.jido, state.id, state.partition)

    orphaned_state =
      state
      |> State.orphan_parent()
      |> State.record_debug_event(:orphaned, %{
        former_parent_id: former_parent.id,
        tag: former_parent.tag,
        reason: reason
      })

    {former_parent, orphaned_state}
  end

  defp hydrate_parent_from_runtime_store(%Options{} = options) do
    case Jido.parent_binding(options.jido, options.id, partition: options.partition) do
      {:ok, %{parent_id: parent_id, parent_partition: parent_partition, tag: tag, meta: meta}} ->
        parent =
          case Jido.whereis(options.jido, parent_id, partition: parent_partition) do
            pid when is_pid(pid) ->
              ParentRef.new!(%{
                pid: pid,
                id: parent_id,
                partition: parent_partition,
                tag: tag,
                meta: normalize_parent_meta(meta)
              })

            nil ->
              _ = clear_parent_binding(options.jido, options.id, options.partition)
              nil
          end

        {:ok, %{options | parent: parent}}

      :error ->
        {:ok, options}
    end
  end

  defp maybe_persist_parent_binding(%State{parent: %ParentRef{} = parent} = state) do
    case Jido.parent_binding(state.jido, state.id, partition: state.partition) do
      {:ok, _binding} ->
        state

      :error ->
        case persist_parent_binding(state.jido, state.id, state.partition, parent) do
          :ok ->
            state

          {:error, reason} ->
            Logger.warning(
              "AgentServer #{state.id} failed to persist parent binding: #{inspect(reason)}"
            )

            state
        end
    end
  end

  defp maybe_persist_parent_binding(state), do: state

  defp persist_parent_binding(jido, child_id, child_partition, %ParentRef{} = parent_ref)
       when is_atom(jido) and is_binary(child_id) do
    RuntimeStore.put(jido, @relationship_hive, Jido.partition_key(child_id, child_partition), %{
      parent_id: parent_ref.id,
      parent_partition: parent_ref.partition,
      tag: parent_ref.tag,
      meta: normalize_parent_meta(parent_ref.meta)
    })
  end

  defp clear_parent_binding(jido, child_id, child_partition)
       when is_atom(jido) and is_binary(child_id) do
    RuntimeStore.delete(jido, @relationship_hive, Jido.partition_key(child_id, child_partition))
  end

  defp normalize_parent_meta(meta) when is_map(meta), do: meta
  defp normalize_parent_meta(_meta), do: %{}

  # ---------------------------------------------------------------------------
  # Internal: Telemetry
  # ---------------------------------------------------------------------------

  defp exec_directive_with_telemetry(directive, signal, state) do
    start_time = System.monotonic_time()

    directive_type =
      directive.__struct__ |> Module.split() |> List.last()

    # Record debug event for directive execution
    state =
      State.record_debug_event(state, :directive_started, %{
        type: directive_type,
        signal_type: signal.type
      })

    trace_metadata = TraceContext.to_telemetry_metadata()

    metadata =
      %{
        agent_id: state.id,
        agent_module: state.agent_module,
        directive_type: directive_type,
        directive: directive,
        signal_type: signal.type,
        jido_instance: state.jido,
        jido_partition: state.partition
      }
      |> Map.merge(trace_metadata)

    emit_telemetry(
      [:jido, :agent_server, :directive, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = DirectiveExec.exec(directive, signal, state)

      emit_telemetry(
        [:jido, :agent_server, :directive, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.merge(metadata, %{result: result_type(result)})
      )

      result
    catch
      kind, reason ->
        emit_telemetry(
          [:jido, :agent_server, :directive, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{kind: kind, error: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp result_type(:ok), do: :ok
  defp result_type({:stop, _}), do: :stop

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end

  # Warn when {:stop, ...} is used with normal-looking reasons.
  # This indicates likely misuse - normal completion should use state.status instead.
  defp warn_if_normal_stop(reason, directive, state)
       when reason in [:normal, :completed, :ok, :done, :success] do
    directive_type = directive.__struct__ |> Module.split() |> List.last()

    Logger.warning("""
    AgentServer #{state.id} received {:stop, #{inspect(reason)}, ...} from directive #{directive_type}.

    This is a HARD STOP: pending directives and async work will be lost, and on_after_cmd/3 will NOT run.

    For normal completion, set state.status to :completed/:failed instead and avoid returning {:stop, ...}.
    External code should poll AgentServer.state/3 with a status selector, not rely on process death.

    {:stop, ...} should only be used for abnormal/framework-level termination.
    """)
  end

  defp warn_if_normal_stop(_reason, _directive, _state), do: :ok
end
