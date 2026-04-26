defimpl Jido.AgentServer.DirectiveExec, for: Jido.Pod.Directive.StartNode do
  @moduledoc false

  alias Jido.AgentServer
  alias Jido.AgentServer.Signal.ChildExit
  alias Jido.Pod.Runtime

  def exec(%{name: name, initial_state: initial, opts: opts}, _input_signal, state) do
    runtime_opts =
      opts
      |> Map.to_list()
      |> Keyword.merge(if initial, do: [initial_state: initial], else: [])

    case Runtime.start_node(state, name, runtime_opts) do
      {:ok, next_state, _pid_or_adopted} ->
        {:ok, next_state}

      {:error, next_state, reason} ->
        # Synthesize a child.exit so MutateProgress treats this as a startup
        # failure and finalizes the mutation rather than hanging on a
        # child.started that will never arrive.
        synthetic =
          ChildExit.new!(
            %{tag: name, pid: nil, reason: {:start_failed, reason}},
            source: "/agent/#{state.id}"
          )

        _ = AgentServer.cast(self(), synthetic)
        {:ok, next_state}
    end
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Pod.Directive.StopNode do
  @moduledoc false

  alias Jido.Pod.Runtime

  def exec(%{name: name, reason: reason}, _input_signal, state) do
    {:ok, next_state} = Runtime.stop_node(state, name, reason)
    {:ok, next_state}
  end
end
