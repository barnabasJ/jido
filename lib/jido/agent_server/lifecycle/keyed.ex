defmodule Jido.AgentServer.Lifecycle.Keyed do
  @moduledoc """
  Lifecycle implementation for keyed/pooled agents.

  Handles attachment tracking and idle timeout. Storage-backed
  hibernate/thaw is no longer a lifecycle concern — `Jido.Middleware.Persister`
  observes `jido.agent.lifecycle.{starting, stopping}` and performs the IO
  inline through the middleware chain.

  ## State

  Adds a `lifecycle` sub-map to server state with:
  - `attachments` - MapSet of attached pids
  - `attachment_monitors` - Map of ref => pid
  - `idle_timer` - timer reference or nil
  - `idle_timeout` - timeout value in milliseconds
  - `pool` - pool name (for logging)
  - `pool_key` - pool key

  ## Events

  - `{:attach, pid}` - attach a process
  - `{:detach, pid}` - detach a process
  - `:touch` - reset idle timer
  - `{:down, ref, pid}` - handle monitor DOWN
  - `:idle_timeout` - handle idle timeout
  """

  @behaviour Jido.AgentServer.Lifecycle

  require Logger

  @impl true
  def init(_opts, state) do
    # Lifecycle struct is already populated by State.from_options/3.
    # Storage-backed thaw is now performed by the Persister middleware
    # observing `jido.agent.lifecycle.starting`, which fires before
    # `handle_continue(:post_init, ...)` calls into this hook.
    maybe_start_idle_timer(state)
  end

  @impl true
  def handle_event({:attach, pid}, state) do
    lifecycle = state.lifecycle

    if MapSet.member?(lifecycle.attachments, pid) do
      {:cont, state}
    else
      ref = Process.monitor(pid)

      new_lifecycle = %{
        lifecycle
        | attachments: MapSet.put(lifecycle.attachments, pid),
          attachment_monitors: Map.put(lifecycle.attachment_monitors, ref, pid)
      }

      state = %{state | lifecycle: new_lifecycle}
      state = cancel_idle_timer(state)

      Logger.debug(
        "Lifecycle attached pid #{inspect(pid)} to #{lifecycle.pool}/#{inspect(lifecycle.pool_key)}"
      )

      {:cont, state}
    end
  end

  def handle_event({:detach, pid}, state) do
    lifecycle = state.lifecycle

    if MapSet.member?(lifecycle.attachments, pid) do
      {ref, monitors} = pop_monitor_by_pid(lifecycle.attachment_monitors, pid)

      if ref do
        Process.demonitor(ref, [:flush])
      end

      new_lifecycle = %{
        lifecycle
        | attachments: MapSet.delete(lifecycle.attachments, pid),
          attachment_monitors: monitors
      }

      state = %{state | lifecycle: new_lifecycle}

      Logger.debug(
        "Lifecycle detached pid #{inspect(pid)} from #{lifecycle.pool}/#{inspect(lifecycle.pool_key)}"
      )

      if MapSet.size(new_lifecycle.attachments) == 0 do
        {:cont, maybe_start_idle_timer(state)}
      else
        {:cont, state}
      end
    else
      {:cont, state}
    end
  end

  def handle_event(:touch, state) do
    state = cancel_idle_timer(state)
    {:cont, maybe_start_idle_timer(state)}
  end

  def handle_event({:down, ref, pid}, state) do
    lifecycle = state.lifecycle

    case Map.get(lifecycle.attachment_monitors, ref) do
      ^pid ->
        new_lifecycle = %{
          lifecycle
          | attachments: MapSet.delete(lifecycle.attachments, pid),
            attachment_monitors: Map.delete(lifecycle.attachment_monitors, ref)
        }

        state = %{state | lifecycle: new_lifecycle}

        Logger.debug(
          "Lifecycle owner #{inspect(pid)} down for #{lifecycle.pool}/#{inspect(lifecycle.pool_key)}"
        )

        if MapSet.size(new_lifecycle.attachments) == 0 do
          {:cont, maybe_start_idle_timer(state)}
        else
          {:cont, state}
        end

      _ ->
        {:cont, state}
    end
  end

  def handle_event(:idle_timeout, state) do
    lifecycle = state.lifecycle

    Logger.debug("Lifecycle idle timeout for #{lifecycle.pool}/#{inspect(lifecycle.pool_key)}")

    {:stop, {:shutdown, :idle_timeout}, state}
  end

  def handle_event(_event, state) do
    {:cont, state}
  end

  @impl true
  def persist_cron_specs(state, cron_specs) do
    case find_persister_opts(state) do
      nil ->
        :ok

      %{storage: nil} ->
        :ok

      %{storage: storage, persistence_key: key} ->
        Jido.Persist.persist_scheduler_manifest(
          storage,
          state.agent_module,
          key,
          state.agent,
          cron_specs
        )
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp find_persister_opts(_state) do
    # Persister opts live inside the closed-over middleware chain function;
    # we can't introspect closures. Instead, the persister opts are mirrored
    # into the lifecycle struct at init time when the chain is built. For
    # now, rely on the InstanceManager wiring: read storage/key from the
    # process dictionary slot Persister stamps during init.
    Process.get(:jido_persister_opts)
  end

  defp maybe_start_idle_timer(state) do
    lifecycle = state.lifecycle
    timeout = lifecycle.idle_timeout

    cond do
      timeout == :infinity or timeout == nil ->
        state

      MapSet.size(lifecycle.attachments) == 0 and is_integer(timeout) and timeout > 0 ->
        # Use a timer ref so stale timeout messages can be ignored safely.
        timer_ref = :erlang.start_timer(timeout, self(), :lifecycle_idle_timeout)
        %{state | lifecycle: %{lifecycle | idle_timer: timer_ref}}

      true ->
        state
    end
  end

  defp cancel_idle_timer(state) do
    lifecycle = state.lifecycle

    if lifecycle.idle_timer do
      :erlang.cancel_timer(lifecycle.idle_timer)
      %{state | lifecycle: %{lifecycle | idle_timer: nil}}
    else
      state
    end
  end

  defp pop_monitor_by_pid(monitors, pid) do
    case Enum.find(monitors, fn {_ref, p} -> p == pid end) do
      {ref, _pid} -> {ref, Map.delete(monitors, ref)}
      nil -> {nil, monitors}
    end
  end
end
