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
      def run(_params, ctx) do
        emit = Jido.Signal.Call.reply(ctx.signal, "my.agent.ping.reply", %{ok: true})
        {:ok, %{}, [emit]}
      end

  ## Why not `Jido.AgentServer.call/2`?

  `AgentServer.call/2` does synchronously dispatch a signal, but it
  replies with the full agent struct — the caller still has to reach
  into private state. This primitive keeps the reply's shape under the
  agent's control (it emits a signal whose `data` is exactly what the
  caller needs, nothing more).

  ## Options

  * `:timeout` - ms to wait for a reply (default `5_000`).
  """

  alias Jido.Agent.Directive.Emit
  alias Jido.AgentServer
  alias Jido.Signal

  @default_timeout 5_000

  @type option :: {:timeout, timeout()}

  @doc """
  Sends `signal` to `server` and waits for a reply signal whose `subject`
  equals the request's `id`.

  Returns `{:ok, reply_signal}` on success, `{:error, :timeout}` if no
  matching reply arrives within the timeout, or any error propagated
  from the `AgentServer.cast/2` call.
  """
  @spec call(AgentServer.server(), Signal.t(), [option]) ::
          {:ok, Signal.t()} | {:error, term()}
  def call(server, %Signal{} = signal, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    correlation_id = signal.id

    query =
      case signal.jido_dispatch do
        nil -> %{signal | jido_dispatch: {:pid, target: self()}}
        _existing -> signal
      end

    with :ok <- AgentServer.cast(server, query) do
      await_reply(correlation_id, timeout)
    end
  end

  defp await_reply(correlation_id, timeout) do
    receive do
      {:signal, %Signal{subject: ^correlation_id} = reply} ->
        {:ok, reply}
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
        nil -> {:ok, %{}}
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
end
