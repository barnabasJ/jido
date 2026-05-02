defmodule Jido.Directives do
  @moduledoc """
  Framework-level directive structs and constructor helpers.

  A *directive* is a pure description of an external effect for the runtime
  (e.g. `Jido.AgentServer`) to execute. Agents and strategies **never**
  interpret or execute directives; they only emit them.

  ## The Bright Line

  - **Directives mutate no state.** Not domain (`agent.state`), not runtime
    (`%AgentServer.State{}`), nothing. They do I/O — emit signals, spawn
    processes, schedule messages, persist to disk — and return immediately.
  - **Results, if any, come back as signals that re-enter the pipeline.**
    Bookkeeping that logically follows the I/O happens via the cascade
    callbacks `process_signal/2` invokes (`maybe_track_child_started/2`,
    `handle_child_down/3`, `maybe_track_cron_registered/2`, …), not inside
    the directive's `exec/3` body.
  - **The type system enforces it.** `Jido.AgentServer.DirectiveExec.exec/3`
    returns `:ok | {:stop, term()}` — there is no state slot in the return
    shape, so a directive author cannot accidentally write one.
  - **All `agent.state` writes flow through the action's return value.**
    Sole exception is middleware `ctx.agent` staging for I/O purposes.

  ## Core Directives

  Each directive is one struct in its own file under `lib/jido/directives/`:

  - `Jido.Directives.Emit` — dispatch a signal via `Jido.Signal.Dispatch`
  - `Jido.Directives.Error` — signal an error (wraps `Jido.Error.t()`)
  - `Jido.Directives.Spawn` — spawn a generic BEAM child process (fire-and-forget, no tracking)
  - `Jido.Directives.SpawnAgent` — spawn a child Jido agent with hierarchy tracking
  - `Jido.Directives.SpawnManagedAgent` — spawn an agent via `Jido.Agent.InstanceManager`
  - `Jido.Directives.AdoptChild` — attach an orphaned child to current parent
  - `Jido.Directives.StopChild` — request a tracked child agent to stop gracefully
  - `Jido.Directives.Schedule` — schedule a delayed message
  - `Jido.Directives.RunInstruction` — execute an instruction and route the result via signal_routes
  - `Jido.Directives.Stop` — stop the agent process (self)
  - `Jido.Directives.Cron` — register a cron schedule
  - `Jido.Directives.CronCancel` — cancel a cron schedule
  - `Jido.Directives.Reply` — reply to a synchronous call

  Slice-owned directives live next to their slice (e.g.
  `Jido.Slices.AiReact.Directives.LLMCall`, `Jido.Pod.Directive.StartNode`).

  ## Usage

      alias Jido.Directives

      # Emit a signal (runtime will dispatch via configured adapters)
      %Directives.Emit{signal: my_signal}
      %Directives.Emit{signal: my_signal, dispatch: {:pubsub, topic: "events"}}
      %Directives.Emit{signal: my_signal, dispatch: {:pid, target: pid}}

      # Schedule for later
      %Directives.Schedule{delay_ms: 5000, message: :timeout}

      # Execute instruction at runtime
      %Directives.RunInstruction{instruction: instruction, result_signal_type: "fsm.instruction.replied"}

  ## Extensibility

  External packages can define their own directive structs:

      defmodule MyApp.Directive.CallLLM do
        defstruct [:model, :prompt, :tag]
      end

  The runtime dispatches on struct type, so no changes to core are needed.
  """

  alias Jido.Directives.{
    Emit,
    Error,
    Spawn,
    SpawnAgent,
    AdoptChild,
    StopChild,
    Schedule,
    RunInstruction,
    Stop,
    Cron,
    CronCancel
  }

  @typedoc """
  Any external directive struct (core or extension).

  This is intentionally `struct()` so external packages can define
  their own directive structs without modifying this type.
  """
  @type t :: struct()

  @typedoc "Built-in core directives."
  @type core ::
          Emit.t()
          | Error.t()
          | Spawn.t()
          | SpawnAgent.t()
          | AdoptChild.t()
          | StopChild.t()
          | Schedule.t()
          | RunInstruction.t()
          | Stop.t()
          | Cron.t()
          | CronCancel.t()

  @typedoc "Restart policy for spawned AgentServer children."
  @type restart_policy :: :permanent | :temporary | :transient

  @restart_policies [:permanent, :temporary, :transient]
  @unsupported_spawn_agent_opts [
    :lifecycle_mod,
    :pool,
    :pool_key,
    :idle_timeout
  ]

  @doc false
  @spec valid_restart_policies() :: [restart_policy()]
  def valid_restart_policies, do: @restart_policies

  @doc false
  @spec validate_restart_policy(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_restart_policy(restart, _opts \\ [])

  def validate_restart_policy(restart, _opts) when restart in @restart_policies, do: :ok

  def validate_restart_policy(restart, _opts) do
    {:error, "restart must be one of #{inspect(@restart_policies)}, got: #{inspect(restart)}"}
  end

  @doc false
  @spec validate_spawn_agent_opts(term()) :: :ok | {:error, String.t()}
  def validate_spawn_agent_opts(opts) when is_map(opts) do
    unsupported_opts =
      @unsupported_spawn_agent_opts
      |> Enum.filter(&Map.has_key?(opts, &1))
      |> Enum.sort()

    case unsupported_opts do
      [] ->
        :ok

      opts ->
        {:error,
         "SpawnAgent does not support lifecycle/persistence opts #{inspect(opts)}; use Jido.Agent.InstanceManager for storage-backed lifecycle"}
    end
  end

  def validate_spawn_agent_opts(opts) do
    {:error, "SpawnAgent opts must be a map, got: #{inspect(opts)}"}
  end

  # ============================================================================
  # Helper Constructors
  # ============================================================================

  @doc """
  Creates an Emit directive.

  If `dispatch` is omitted, runtime will use `AgentServer` `default_dispatch`.
  When no default is configured, runtime falls back to emitting to the current
  agent process (`self()`).

  ## Examples

      Directives.emit(signal)
      Directives.emit(signal, {:pubsub, topic: "events"})
  """
  @spec emit(term(), term()) :: Emit.t()
  def emit(signal, dispatch \\ nil) do
    %Emit{signal: signal, dispatch: dispatch}
  end

  @doc """
  Creates an Error directive.

  ## Examples

      Directives.error(Jido.Error.validation_error("Invalid input"))
      Directives.error(error, :normalize)
  """
  @spec error(term(), atom() | nil) :: Error.t()
  def error(error, context \\ nil) do
    %Error{error: error, context: context}
  end

  @doc """
  Creates a Spawn directive.

  ## Examples

      Directives.spawn({MyWorker, arg: value})
      Directives.spawn(child_spec, :worker_1)
  """
  @spec spawn(term(), term()) :: Spawn.t()
  def spawn(child_spec, tag \\ nil) do
    %Spawn{child_spec: child_spec, tag: tag}
  end

  @doc """
  Creates a SpawnAgent directive for spawning child agents with hierarchy tracking.

  ## Options

  - `:opts` - Additional options for the child AgentServer (map)
    - Supports child startup options like `:id`, `:initial_state`, and `:on_parent_death`
    - Does not support InstanceManager lifecycle options like `:idle_timeout`,
      `:lifecycle_mod`, `:pool`, or `:pool_key`
  - `:meta` - Metadata to pass to the child via parent reference (map)
  - `:restart` - Child restart policy under supervision (default: `:transient`)

  ## Examples

      Directives.spawn_agent(MyWorkerAgent, :worker_1)
      Directives.spawn_agent(MyWorkerAgent, :processor, opts: %{initial_state: %{batch_size: 100}})
      Directives.spawn_agent(MyWorkerAgent, :handler, meta: %{assigned_topic: "events"})
      Directives.spawn_agent(MyWorkerAgent, :durable, restart: :permanent)
  """
  @spec spawn_agent(term(), term(), keyword()) :: SpawnAgent.t()
  def spawn_agent(agent, tag, options \\ []) do
    opts = Keyword.get(options, :opts, %{})
    meta = Keyword.get(options, :meta, %{})
    restart = Keyword.get(options, :restart, :transient)

    case validate_restart_policy(restart) do
      :ok ->
        case validate_spawn_agent_opts(opts) do
          :ok ->
            %SpawnAgent{agent: agent, tag: tag, opts: opts, meta: meta, restart: restart}

          {:error, message} ->
            raise Jido.Error.validation_error(message, field: :opts)
        end

      {:error, message} ->
        raise Jido.Error.validation_error(message, field: :restart)
    end
  end

  @doc """
  Creates a SpawnManagedAgent directive for spawning an agent via InstanceManager.

  ## Options

  - `:initial_state` - Initial state map (default: `%{}`)
  - `:agent_opts` - Extra AgentServer options (default: `[]`)

  ## Examples

      Directives.spawn_managed_agent(:threads, "thread-123", :worker)
      Directives.spawn_managed_agent(:threads, "thread-123", :worker,
        initial_state: %{thread_id: "thread-123"},
        agent_opts: [parent: %{pid: self(), id: "parent-1", tag: :worker}]
      )
  """
  @spec spawn_managed_agent(atom(), String.t(), term(), keyword()) ::
          Jido.Directives.SpawnManagedAgent.t()
  def spawn_managed_agent(namespace, key, tag, options \\ []) do
    %Jido.Directives.SpawnManagedAgent{
      namespace: namespace,
      key: key,
      tag: tag,
      initial_state: Keyword.get(options, :initial_state, %{}),
      agent_opts: Keyword.get(options, :agent_opts, [])
    }
  end

  @doc """
  Creates an AdoptChild directive for explicitly attaching a child to the current parent.

  ## Options

  - `:meta` - Metadata to write into the adopted child's new parent reference (map)

  ## Examples

      Directives.adopt_child(child_pid, :worker_1)
      Directives.adopt_child("child-agent-id", :worker_1, meta: %{restored: true})
  """
  @spec adopt_child(pid() | String.t(), term(), keyword()) :: AdoptChild.t()
  def adopt_child(child, tag, opts \\ [])

  def adopt_child(child, tag, opts) when is_pid(child) or is_binary(child) do
    %AdoptChild{
      child: child,
      tag: tag,
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  def adopt_child(child, _tag, _opts) do
    raise Jido.Error.validation_error(
            "child must be a PID or child id string, got: #{inspect(child)}",
            field: :child
          )
  end

  @doc """
  Creates a StopChild directive to gracefully stop a tracked child agent.

  ## Examples

      Directives.stop_child(:worker_1)
      Directives.stop_child(:processor, :shutdown)
  """
  @spec stop_child(term(), term()) :: StopChild.t()
  def stop_child(tag, reason \\ :normal) do
    %StopChild{tag: tag, reason: reason}
  end

  @doc """
  Creates a Schedule directive.

  ## Examples

      Directives.schedule(5000, :timeout)
      Directives.schedule(1000, {:check, ref})
  """
  @spec schedule(non_neg_integer(), term()) :: Schedule.t()
  def schedule(delay_ms, message) do
    %Schedule{delay_ms: delay_ms, message: message}
  end

  @doc """
  Creates a RunInstruction directive.

  ## Options

  - `:result_signal_type` - Required signal type used to route the
    execution result. Bind it via the agent's `signal_routes/1` to an
    action that consumes the result payload.
  - `:meta` - Optional metadata echoed in result payload (map)

  ## Examples

      Directives.run_instruction(instruction,
        result_signal_type: "myapp.instruction.replied"
      )

      # In the agent:
      def signal_routes(_ctx) do
        [{"myapp.instruction.replied", MyApp.HandleInstructionResult}]
      end
  """
  @spec run_instruction(Jido.Instruction.t(), keyword()) :: RunInstruction.t()
  def run_instruction(%Jido.Instruction{} = instruction, opts) do
    result_signal_type =
      Keyword.fetch!(opts, :result_signal_type)

    %RunInstruction{
      instruction: instruction,
      result_signal_type: result_signal_type,
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc """
  Creates a Stop directive.

  ## Examples

      Directives.stop()
      Directives.stop(:shutdown)
  """
  @spec stop(term()) :: Stop.t()
  def stop(reason \\ :normal) do
    %Stop{reason: reason}
  end

  @doc """
  Creates a Cron directive for recurring scheduled execution.

  ## Options

  - `:job_id` - Logical id for the job (for upsert/cancel)
  - `:timezone` - Timezone identifier

  ## Examples

      Directives.cron("* * * * *", tick_signal)
      Directives.cron("@daily", cleanup_signal, job_id: :daily_cleanup)
      Directives.cron("0 9 * * MON", weekly_signal, job_id: :monday_9am, timezone: "America/New_York")
  """
  @spec cron(term(), term(), keyword()) :: Cron.t()
  def cron(cron_expr, message, opts \\ []) do
    %Cron{
      cron: cron_expr,
      message: message,
      job_id: Keyword.get(opts, :job_id),
      timezone: Keyword.get(opts, :timezone)
    }
  end

  @doc """
  Creates a CronCancel directive to stop a recurring job.

  ## Examples

      Directives.cron_cancel(:heartbeat)
      Directives.cron_cancel(:daily_cleanup)
  """
  @spec cron_cancel(term()) :: CronCancel.t()
  def cron_cancel(job_id) do
    %CronCancel{job_id: job_id}
  end

  # ============================================================================
  # Multi-Agent Communication Helpers
  # ============================================================================

  @doc """
  Creates an Emit directive targeting a specific process by PID.

  This is a convenience for sending signals directly to another agent or process.

  ## Options

  All options are passed to the `:pid` dispatch adapter:
  - `:delivery_mode` - `:async` (default) or `:sync`
  - `:timeout` - Timeout for sync delivery (default: 5000)

  ## Examples

      Directives.emit_to_pid(signal, some_pid)
      Directives.emit_to_pid(signal, worker_pid, delivery_mode: :sync)
  """
  @spec emit_to_pid(term(), pid(), Keyword.t()) :: Emit.t()
  def emit_to_pid(signal, pid, extra_opts \\ []) when is_pid(pid) do
    opts = Keyword.merge([target: pid], extra_opts)
    %Emit{signal: signal, dispatch: {:pid, opts}}
  end
end
