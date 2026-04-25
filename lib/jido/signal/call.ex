defmodule Jido.Signal.Call do
  @moduledoc """
  Synchronous request / reply over signals.

  The standard way to ask an agent for information today is
  `Jido.AgentServer.state/1` — pull the whole state struct out and dig. That
  leaks internal layout to callers and forces the agent to be transparent.
  Signals are the natural alternative: the caller dispatches a query
  signal, the agent routes it to an action that produces an answer, and
  the answer comes back as its own signal.

  `call/3` wires the two halves together:

  * The caller attaches `jido_dispatch: {:pid, target: self()}` to the
    query signal and casts it to the agent.
  * Once the agent's action runs, it uses `reply/3` (below) to build an
    `%Emit{}` directive whose signal has `subject: query.id` and whose
    dispatch is copied from the query. The runtime delivers it as
    `{:signal, reply_signal}` to the caller's mailbox.
  * `call/3` blocks in a receive that matches on the correlation id and
    returns the reply's data.

  ## Example

      # Client
      {:ok, query} = Jido.Signal.new("my.agent.ping", %{}, source: "/x")
      {:ok, reply} = Jido.Signal.Call.call(agent_pid, query)

      # Action handling "my.agent.ping"
      def run(_signal, slice, _opts, ctx) do
        emit = Jido.Signal.Call.reply(ctx.signal, "my.agent.ping.reply", %{ok: true})
        {:ok, %{}, List.wrap(emit)}
      end

  ## Why not `Jido.AgentServer.call/2`?

  `AgentServer.call/2` does synchronously dispatch a signal, but it
  replies with the full agent struct — the caller still has to reach
  into private state. This primitive keeps the reply's shape under the
  agent's control (it emits a signal whose `data` is exactly what the
  caller needs, nothing more).

  ## Options

  * `:timeout` - ms to wait for a reply. Defaults to
    `Application.get_env(:jido, :call_timeout_ms, 5_000)`.
  """

  alias Jido.Agent.Directive.Emit
  alias Jido.Agent.Directive.Reply
  alias Jido.AgentServer
  alias Jido.Signal

  @default_timeout 5_000

  @type option :: {:timeout, timeout()}

  @doc "Returns the default call timeout in ms (app-env overridable)."
  @spec default_timeout() :: timeout()
  def default_timeout do
    Application.get_env(:jido, :call_timeout_ms, @default_timeout)
  end

  @doc """
  Sends `signal` to `server` and waits for a reply signal whose `subject`
  equals the request's `id`.

  Returns `{:ok, reply_signal}` on success, `{:error, :timeout}` if no
  matching reply arrives within the timeout, `{:error, :noproc}` if the
  target process dies before replying, or any error propagated from
  server resolution (e.g. `{:error, :not_found}` for an unregistered
  name).
  """
  @spec call(AgentServer.server(), Signal.t(), [option]) ::
          {:ok, Signal.t()} | {:error, term()}
  def call(server, %Signal{} = signal, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    correlation_id = signal.id

    query =
      case signal.jido_dispatch do
        nil -> %{signal | jido_dispatch: {:pid, target: self()}}
        _existing -> signal
      end

    with {:ok, pid} <- AgentServer.resolve(server) do
      ref = Process.monitor(pid)
      :ok = GenServer.cast(pid, {:signal, query})

      try do
        await_reply(correlation_id, ref, timeout)
      after
        Process.demonitor(ref, [:flush])
      end
    end
  end

  defp await_reply(correlation_id, monitor_ref, timeout) do
    receive do
      {:signal, %Signal{subject: ^correlation_id} = reply} ->
        {:ok, reply}

      {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
        {:error, :noproc}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc """
  Builds an `%Emit{}` directive that replies to an input query signal.

  `reply_type` is the type of the reply signal; `data` is its payload.
  The reply's `subject` is set to the input signal's `id`, and the
  reply's dispatch is copied from the input signal — which is how
  `call/3` finds it back.

  Returns `nil` if the input signal lacks a reply dispatch (i.e. it was
  not sent by `call/3` and the caller isn't expecting an answer). That
  lets action code be flexible:

      case Jido.Signal.Call.reply(ctx.signal, "my.reply", %{value: 42}) do
        nil -> {:ok, %{}, []}
        emit -> {:ok, %{}, [emit]}
      end
  """
  @spec reply(Signal.t() | nil, String.t(), map()) :: Emit.t() | nil
  def reply(nil, _type, _data), do: nil
  def reply(%Signal{jido_dispatch: nil}, _type, _data), do: nil

  def reply(%Signal{id: req_id, jido_dispatch: dispatch}, reply_type, data)
      when is_binary(reply_type) and is_map(data) do
    {:ok, reply_signal} = Signal.new(reply_type, data, subject: req_id)
    %Emit{signal: reply_signal, dispatch: dispatch}
  end

  @doc """
  Builds a `%Jido.Agent.Directive.Reply{}` directive that will construct
  the reply *at directive execution time* by calling `{m, f, extra_args}`
  with the full `%AgentServer.State{}`.

  Use this when the action knows a query came in but doesn't itself have
  the server-level information needed to answer it — e.g. running pids
  resolved through a Registry. The directive executor has access to
  `%State{}` by protocol, so introspection code belongs there.

  `build_mfa` must resolve to `apply(m, f, [state | extra_args]) -> {:ok, map} | {:error, term}`.

  On success the reply has `type: reply_type` and `data: the returned map`.
  On error the reply has `type: error_type` and `data: %{reason: reason}`.

  Returns `nil` if the input signal has no `jido_dispatch` (fire-and-forget).

  ## Example

      # Action
      def run(_signal, slice, _opts, ctx) do
        directive =
          Call.reply_from_state(
            ctx.signal,
            "jido.pod.query.nodes.reply",
            "jido.pod.query.nodes.error",
            {Jido.Pod.Queries, :build_nodes_reply, []}
          )

        {:ok, %{}, List.wrap(directive)}
      end

      # Builder — sees the full %State{}
      def build_nodes_reply(%Jido.AgentServer.State{} = state) do
        with {:ok, topology} <- Jido.Pod.TopologyState.fetch_topology(state) do
          {:ok, %{topology: topology, nodes: Jido.Pod.Runtime.build_node_snapshots(state, topology)}}
        end
      end
  """
  @spec reply_from_state(
          Signal.t() | nil,
          String.t(),
          String.t(),
          Reply.builder()
        ) :: Reply.t() | nil
  def reply_from_state(nil, _reply_type, _error_type, _build_mfa), do: nil
  def reply_from_state(%Signal{jido_dispatch: nil}, _r, _e, _b), do: nil

  def reply_from_state(%Signal{} = input, reply_type, error_type, {m, f, a})
      when is_binary(reply_type) and is_binary(error_type) and is_atom(m) and is_atom(f) and
             is_list(a) do
    %Reply{
      input_signal: input,
      reply_type: reply_type,
      error_type: error_type,
      build: {m, f, a}
    }
  end
end
