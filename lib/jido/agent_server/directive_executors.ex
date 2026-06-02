defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.Emit do
  @moduledoc false

  alias Jido.Tracing.Context, as: TraceContext

  require Logger

  def exec(%{signal: signal, dispatch: dispatch}, input_signal, state) do
    cfg = dispatch || state.default_dispatch

    traced_signal =
      case TraceContext.propagate_to(signal, input_signal.id) do
        {:ok, s} -> s
        {:error, _} -> signal
      end

    dispatch_signal(traced_signal, cfg, state)

    :ok
  end

  defp dispatch_signal(traced_signal, nil, _state) do
    send(self(), {:signal, traced_signal})
  end

  defp dispatch_signal(traced_signal, cfg, state) do
    if Code.ensure_loaded?(Jido.Signal.Dispatch) do
      task_sup =
        if state.jido, do: Jido.task_supervisor_name(state.jido), else: Jido.TaskSupervisor

      Task.Supervisor.start_child(task_sup, fn ->
        Jido.Signal.Dispatch.dispatch(traced_signal, cfg)
      end)
    else
      Logger.warning("Jido.Signal.Dispatch not available, skipping emit")
    end
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.Error do
  @moduledoc false

  # The framework-level error policy is gone (C4 of ADR 0014). Error
  # directives just log and continue; users who need stop-on-error or
  # max-errors semantics write a small middleware that pattern-matches on
  # `%Directives.Error{}` in the chain result. A formal error-handling
  # surface lands in a follow-up PR per task 0004 S6.

  require Logger

  def exec(%Jido.Directives.Error{error: error, context: context}, _input_signal, state) do
    Logger.error("Agent #{state.id}#{format_context(context)}: #{format_error(error)}")

    :ok
  end

  defp format_context(nil), do: ""
  defp format_context(ctx), do: " [#{ctx}]"

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(error), do: inspect(error)
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.RunInstruction do
  @moduledoc """
  Pure I/O directive: runs the instruction and emits a result signal of
  type `result_signal_type`. The directive does not call `cmd/2`
  directly — the agent's `signal_routes` binds `result_signal_type` to
  a handler action that performs the slice update via its return value.
  The handler runs on the next mailbox turn through the normal pipeline.
  """

  alias Jido.AgentServer
  alias Jido.Observe.Config, as: ObserveConfig

  def exec(
        %{instruction: instruction, result_signal_type: signal_type, meta: meta},
        _input_signal,
        state
      ) do
    enriched_instruction = %{
      instruction
      | context: Map.put(instruction.context || %{}, :state, state.agent.state)
    }

    execution_payload =
      enriched_instruction
      |> then(fn instruction ->
        exec_opts = ObserveConfig.action_exec_opts(state.jido, instruction.opts)
        Jido.Exec.run(%{instruction | opts: exec_opts})
      end)
      |> normalize_result_payload()
      |> Map.put(:instruction, instruction)
      |> Map.put(:meta, meta || %{})

    result_signal =
      Jido.Signal.new!(signal_type, execution_payload, source: "/agent/#{state.id}")

    _ = AgentServer.cast(self(), result_signal)
    :ok
  end

  defp normalize_result_payload({:ok, result, effects}) do
    %{
      status: :ok,
      result: result,
      effects: List.wrap(effects)
    }
  end

  defp normalize_result_payload({:error, reason}) do
    %{
      status: :error,
      reason: reason,
      effects: []
    }
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.Spawn do
  @moduledoc false

  require Logger

  def exec(%{child_spec: child_spec, tag: tag}, _input_signal, state) do
    result =
      if is_function(state.spawn_fun, 1) do
        state.spawn_fun.(child_spec)
      else
        agent_sup =
          if state.jido, do: Jido.agent_supervisor_name(state.jido), else: Jido.AgentSupervisor

        DynamicSupervisor.start_child(agent_sup, child_spec)
      end

    case result do
      {:ok, pid} ->
        Logger.debug("Spawned child process #{inspect(pid)} with tag #{inspect(tag)}")
        :ok

      {:ok, pid, _info} ->
        Logger.debug("Spawned child process #{inspect(pid)} with tag #{inspect(tag)}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to spawn child: #{inspect(reason)}")
        :ok

      :ignored ->
        :ok
    end
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.AsyncTask do
  @moduledoc false

  alias Jido.AgentServer
  alias Jido.AgentServer.State
  alias Jido.Directives.AsyncTask
  alias Jido.Signal
  alias Jido.Tracing.Context, as: TraceContext

  require Logger

  @impl Jido.AgentServer.DirectiveExec
  @spec exec(directive :: AsyncTask.t(), input_signal :: Signal.t(), state :: State.t()) :: :ok
  def exec(%AsyncTask{} = directive, input_signal, %State{} = state) do
    agent_pid = self()
    task_sup = task_supervisor(state)

    case Task.Supervisor.start_child(task_sup, fn ->
           run_and_dispatch(directive, input_signal, state, agent_pid)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        directive
        |> error_signal(reason, state)
        |> dispatch_signals(input_signal, reply_target(directive, agent_pid), state)
    end

    :ok
  end

  @spec task_supervisor(state :: State.t()) :: module()
  defp task_supervisor(%State{} = state) do
    if state.jido, do: Jido.task_supervisor_name(state.jido), else: Jido.TaskSupervisor
  end

  @spec run_and_dispatch(
          directive :: AsyncTask.t(),
          input_signal :: Signal.t(),
          state :: State.t(),
          agent_pid :: pid()
        ) :: :ok
  defp run_and_dispatch(
         %AsyncTask{} = directive,
         %Signal{} = input_signal,
         %State{} = state,
         agent_pid
       ) do
    signals =
      directive
      |> run_work(input_signal, state)
      |> normalize_result(directive, state)

    dispatch_signals(signals, input_signal, reply_target(directive, agent_pid), state)
  end

  @spec run_work(directive :: AsyncTask.t(), input_signal :: Signal.t(), state :: State.t()) ::
          term()
  defp run_work(%AsyncTask{work: work}, %Signal{} = input_signal, %State{} = state) do
    invoke_work(work, task_context(input_signal, state))
  rescue
    exception ->
      {:error, %{kind: :error, reason: exception, stacktrace: __STACKTRACE__}}
  catch
    kind, reason ->
      {:error, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__}}
  end

  @spec invoke_work(work :: AsyncTask.work(), context :: map()) :: term()
  defp invoke_work({module, function, args}, _context)
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  end

  defp invoke_work(fun, _context) when is_function(fun, 0), do: fun.()
  defp invoke_work(fun, context) when is_function(fun, 1), do: fun.(context)
  defp invoke_work(other, _context), do: {:error, {:invalid_async_task_work, other}}

  @spec task_context(input_signal :: Signal.t(), state :: State.t()) :: map()
  defp task_context(%Signal{} = input_signal, %State{} = state) do
    %{
      agent_id: state.id,
      input_signal: input_signal,
      jido: state.jido,
      partition: state.partition
    }
  end

  @spec normalize_result(result :: term(), directive :: AsyncTask.t(), state :: State.t()) :: [
          Signal.t()
        ]
  defp normalize_result(%Signal{} = signal, _directive, _state), do: [signal]
  defp normalize_result({:ok, %Signal{} = signal}, _directive, _state), do: [signal]
  defp normalize_result({:signals, signals}, _directive, _state), do: valid_signals(signals)

  defp normalize_result({:ok, {:signals, signals}}, _directive, _state),
    do: valid_signals(signals)

  defp normalize_result({:ok, result}, %AsyncTask{} = directive, %State{} = state) do
    [success_signal(directive, result, state)]
  end

  defp normalize_result(
         {:error, %{kind: kind, reason: reason}},
         %AsyncTask{} = directive,
         %State{} = state
       ) do
    [error_signal(directive, reason, state, %{kind: kind})]
  end

  defp normalize_result({:error, reason}, %AsyncTask{} = directive, %State{} = state) do
    [error_signal(directive, reason, state)]
  end

  defp normalize_result(result, %AsyncTask{} = directive, %State{} = state) do
    [success_signal(directive, result, state)]
  end

  @spec valid_signals(signals :: term()) :: [Signal.t()]
  defp valid_signals(signals) when is_list(signals) do
    Enum.filter(signals, &match?(%Signal{}, &1))
  end

  defp valid_signals(_signals), do: []

  @spec success_signal(directive :: AsyncTask.t(), result :: term(), state :: State.t()) ::
          Signal.t()
  defp success_signal(%AsyncTask{} = directive, result, %State{} = state) do
    data = Map.put(directive.payload || %{}, :result, result)
    Signal.new!(directive.success_type, data, source: signal_source(directive, state))
  end

  @spec error_signal(
          directive :: AsyncTask.t(),
          reason :: term(),
          state :: State.t(),
          extra :: map()
        ) :: Signal.t()
  defp error_signal(%AsyncTask{} = directive, reason, %State{} = state, extra \\ %{}) do
    data =
      (directive.payload || %{})
      |> Map.merge(extra)
      |> Map.put(:reason, reason)

    Signal.new!(directive.error_type, data, source: signal_source(directive, state))
  end

  @spec signal_source(directive :: AsyncTask.t(), state :: State.t()) :: String.t()
  defp signal_source(%AsyncTask{source: source}, _state) when is_binary(source), do: source
  defp signal_source(_directive, %State{} = state), do: "/agent/#{state.id}/async_task"

  @spec reply_target(directive :: AsyncTask.t(), agent_pid :: pid()) :: GenServer.server()
  defp reply_target(%AsyncTask{target: nil}, agent_pid), do: agent_pid
  defp reply_target(%AsyncTask{target: target}, _agent_pid), do: target

  @spec dispatch_signals(
          signals :: [Signal.t()] | Signal.t(),
          input_signal :: Signal.t(),
          target :: GenServer.server(),
          state :: State.t()
        ) :: :ok
  defp dispatch_signals(%Signal{} = signal, %Signal{} = input_signal, target, %State{} = state) do
    dispatch_signals([signal], input_signal, target, state)
  end

  defp dispatch_signals(signals, %Signal{} = input_signal, target, %State{} = state)
       when is_list(signals) do
    Enum.each(signals, fn signal -> safe_cast(target, trace(signal, input_signal), state) end)
    :ok
  end

  @spec trace(signal :: Signal.t(), input_signal :: Signal.t()) :: Signal.t()
  defp trace(%Signal{} = signal, %Signal{} = input_signal) do
    case TraceContext.propagate_to(signal, input_signal.id) do
      {:ok, traced} -> traced
      {:error, _reason} -> signal
    end
  end

  @spec safe_cast(target :: GenServer.server(), signal :: Signal.t(), state :: State.t()) :: :ok
  defp safe_cast(target, %Signal{} = signal, %State{} = state) do
    _ = AgentServer.cast(target, signal)
    :ok
  rescue
    exception ->
      Logger.warning(
        "AgentServer #{state.id} async task could not cast #{signal.type} to #{inspect(target)}: " <>
          Exception.message(exception)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "AgentServer #{state.id} async task could not cast #{signal.type} to #{inspect(target)}: " <>
          inspect(reason)
      )

      :ok
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.Schedule do
  @moduledoc false

  alias Jido.AgentServer.Signal.Scheduled
  alias Jido.Tracing.Context, as: TraceContext

  def exec(%{delay_ms: delay, message: message}, input_signal, state) do
    signal =
      case message do
        %Jido.Signal{} = s ->
          s

        other ->
          Scheduled.new!(
            %{message: other},
            source: "/agent/#{state.id}"
          )
      end

    traced_signal =
      case TraceContext.propagate_to(signal, input_signal.id) do
        {:ok, s} -> s
        {:error, _} -> signal
      end

    Process.send_after(self(), {:scheduled_signal, traced_signal}, delay)
    :ok
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.SpawnAgent do
  @moduledoc """
  Pure I/O directive: spawns the child via the agent supervisor and
  persists the parent ⇒ child relationship in `Jido.RuntimeStore`. The
  child's own `notify_parent_of_startup/1` then casts
  `jido.agent.child.started` back to this agent, where
  `maybe_track_child_started/2` records the `%ChildInfo{}` and creates
  the parent-side monitor.

  Async window: between the directive returning and the natural
  `child.started` arriving, `state.children[tag]` is `nil`. Tests should
  use `AgentServer.await_child/3` rather than peeking at `state.children`
  immediately.
  """

  alias Jido.AgentServer
  alias Jido.Directives
  alias Jido.RuntimeStore

  require Logger

  @relationship_hive :relationships
  @reserved_child_opts [:agent, :agent_module, :id, :jido, :parent, :partition]

  def exec(
        %{agent: agent, tag: tag, opts: opts, meta: meta, restart: restart},
        _input_signal,
        state
      ) do
    with :ok <- Directives.validate_restart_policy(restart),
         :ok <- Directives.validate_spawn_agent_opts(opts) do
      spawn_child(state, agent, tag, opts, meta, restart)
    else
      {:error, reason} ->
        Logger.error("AgentServer #{state.id} failed to spawn child: #{reason}")
        :ok
    end
  end

  defp resolve_agent_module(agent) when is_atom(agent), do: agent
  defp resolve_agent_module(%{__struct__: module}), do: module
  defp resolve_agent_module(_), do: nil

  defp spawn_child(state, agent, tag, opts, meta, restart) do
    child_id = opts[:id] || "#{state.id}/#{tag}"
    child_partition = Map.get(opts, :partition, state.partition)
    agent_module = resolve_agent_module(agent)

    parent_ref = %{
      pid: self(),
      id: state.id,
      partition: state.partition,
      tag: tag,
      meta: meta
    }

    child_opts =
      opts
      |> Map.drop(@reserved_child_opts)
      |> Map.put(:agent_module, agent_module)
      |> Map.put(:id, child_id)
      |> Map.put(:partition, child_partition)
      |> Map.put(:parent, parent_ref)
      |> maybe_put_jido(state.jido)
      |> Map.to_list()

    child_spec = Supervisor.child_spec({AgentServer, child_opts}, restart: restart)

    supervisor =
      if state.jido, do: Jido.agent_supervisor_name(state.jido), else: Jido.AgentSupervisor

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} ->
        case persist_relationship(state, child_id, child_partition, tag, meta) do
          :ok ->
            Logger.debug(
              "AgentServer #{state.id} spawned child #{child_id} with tag #{inspect(tag)}"
            )

            :ok

          {:error, reason} ->
            _ = DynamicSupervisor.terminate_child(supervisor, pid)

            Logger.error(
              "AgentServer #{state.id} failed to persist relationship for child #{child_id}: #{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to spawn child with restart #{inspect(restart)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp persist_relationship(state, child_id, child_partition, tag, meta) do
    RuntimeStore.put(
      state.jido,
      @relationship_hive,
      Jido.partition_key(child_id, child_partition),
      %{
        parent_id: state.id,
        parent_partition: state.partition,
        tag: tag,
        meta: normalize_meta(meta)
      }
    )
  end

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_meta), do: %{}

  defp maybe_put_jido(opts, nil), do: opts
  defp maybe_put_jido(opts, jido), do: Map.put(opts, :jido, jido)
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.AdoptChild do
  @moduledoc """
  Pure I/O directive: pushes a fresh `%ParentRef{}` into the live child
  via `AgentServer.adopt_parent/2`. The child's
  `notify_parent_of_startup/1` then casts `jido.agent.child.started`
  back to this agent, where `maybe_track_child_started/2` records the
  `%ChildInfo{}` and creates the parent-side monitor.

  This is the directive form. The imperative
  `Jido.AgentServer.adopt_child/4` (a `handle_call` callback) keeps
  doing the state mutation directly; only the directive defers to the
  cascade.

  Async window: between the directive returning and the natural
  `child.started` arriving, `state.children[tag]` is `nil`. Tests should
  use `AgentServer.await_child/3` rather than peeking at `state.children`
  immediately.
  """

  alias Jido.AgentServer
  alias Jido.AgentServer.{ParentRef, State}

  require Logger

  def exec(%{child: child, tag: tag, meta: meta}, _input_signal, state) do
    with :ok <- ensure_tag_available(state, tag),
         {:ok, child_pid} <- resolve_child(child, state),
         :ok <- ensure_not_self(child_pid),
         {:ok, child_runtime} <- adopt_child(child_pid, tag, meta, state) do
      Logger.debug(
        "AgentServer #{state.id} initiated adoption of child #{child_runtime.id} with tag #{inspect(tag)}"
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "AgentServer #{state.id} failed to adopt child #{inspect(child)} with tag #{inspect(tag)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ensure_tag_available(state, tag) do
    case State.get_child(state, tag) do
      nil -> :ok
      _child -> {:error, {:tag_in_use, tag}}
    end
  end

  defp resolve_child(pid, _state) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :child_not_alive}
  end

  defp resolve_child(id, state) when is_binary(id) do
    case Jido.whereis(state.jido, id, partition: state.partition) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :child_not_found}
    end
  end

  defp resolve_child(child, _state), do: {:error, {:invalid_child, child}}

  defp ensure_not_self(pid) when pid == self(), do: {:error, :cannot_adopt_self}
  defp ensure_not_self(_pid), do: :ok

  defp adopt_child(child_pid, tag, meta, state) do
    parent_ref =
      ParentRef.new!(%{
        pid: self(),
        id: state.id,
        partition: state.partition,
        tag: tag,
        meta: meta
      })

    AgentServer.adopt_parent(child_pid, parent_ref)
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.StopChild do
  @moduledoc false

  alias Jido.AgentServer.StopChildRuntime

  def exec(%{tag: tag, reason: reason}, input_signal, state) do
    StopChildRuntime.exec(tag, reason, input_signal, state)
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.Stop do
  @moduledoc false

  def exec(%{reason: reason}, _input_signal, _state) do
    {:stop, reason}
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.SpawnManagedAgent do
  @moduledoc false

  alias Jido.Directives.SpawnManagedAgent

  require Logger

  # Delegate to SpawnManagedAgent.execute/2 (the single source of truth for
  # "spawn via InstanceManager with a parent ref") and discard the pid to
  # fit the DirectiveExec :ok contract. Non-directive callers like
  # Jido.Slices.Pod.Runtime use execute/2 directly and keep the pid.
  def exec(directive, _input_signal, state) do
    case SpawnManagedAgent.execute(directive, state) do
      {:ok, _pid} ->
        Logger.debug(
          "SpawnManagedAgent #{state.id}: #{directive.tag} at #{directive.namespace}/#{directive.key}"
        )

        :ok

      {:error, reason} ->
        Logger.error("SpawnManagedAgent #{state.id}: failed #{directive.tag}: #{inspect(reason)}")

        :ok
    end
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Directives.Reply do
  @moduledoc false

  alias Jido.Signal
  alias Jido.Signal.Dispatch

  require Logger

  def exec(%{input_signal: nil}, _input_signal, _state), do: :ok

  def exec(%{input_signal: %{jido_dispatch: nil}}, _input_signal, _state) do
    # No reply channel on the input signal — caller wasn't using
    # Signal.Call.call/3, so there's no one to reply to.
    :ok
  end

  def exec(
        %Jido.Directives.Reply{
          input_signal: input,
          reply_type: reply_type,
          error_type: error_type,
          build: {module, fun, extra_args}
        },
        _input_signal,
        state
      ) do
    {type, data} =
      case apply(module, fun, [state | extra_args]) do
        {:ok, data} when is_map(data) -> {reply_type, data}
        {:error, reason} -> {error_type, %{reason: reason}}
      end

    case Signal.new(type, data, subject: input.id) do
      {:ok, reply_signal} ->
        _ = Dispatch.dispatch(reply_signal, input.jido_dispatch)
        :ok

      {:error, reason} ->
        Logger.warning(
          "Reply directive: failed to build #{inspect(type)} reply signal: #{inspect(reason)}"
        )
    end

    :ok
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Any do
  @moduledoc false

  require Logger

  def exec(directive, _input_signal, _state) do
    Logger.debug("Ignoring unknown directive: #{inspect(directive.__struct__)}")
    :ok
  end
end
