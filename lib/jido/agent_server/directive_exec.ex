defprotocol Jido.AgentServer.DirectiveExec do
  @moduledoc """
  Protocol for executing directives in AgentServer.

  Implement this protocol for custom directive types to extend AgentServer
  with new effect handlers without modifying core code.

  ## Return Values

  - `:ok` — directive executed successfully, continue processing
  - `{:stop, reason}` — **hard stop** the agent process (see warning below)

  Directives never return state. State is passed in as the third arg
  (for reading); mutating it is impossible by the type signature.
  Bookkeeping that logically follows the I/O happens via the cascade
  callbacks `process_signal/2` invokes (`maybe_track_child_started/2`,
  `handle_child_down/3`, `maybe_track_cron_registered/2`,
  `maybe_track_cron_cancelled/2`).

  Failure handling: directives that hit an internal error log it and
  return `:ok` — the same swallow-and-continue convention the `Error`
  directive already follows. There is no `{:error, _}` return because
  `execute_directives/3` would have nowhere meaningful to send it; if
  the failure should abort the batch and stop the agent, escalate via
  `{:stop, reason}`.

  ### The async pattern

  There is no special `{:async, ...}` return. If a directive needs to do
  work that could block the GenServer:

  1. Spawn a supervised task for the side-effect.
  2. When the task finishes, emit a **signal** back to the agent — the
     signal routes through the normal pipeline and an action bound via
     `signal_routes` settles the result onto the agent's slice via its
     return value.

  Loading markers, success/error settles, and any other state changes
  live in actions. Directives never write `agent.state` or
  `%AgentServer.State{}` runtime fields — those flow through the
  cascade callbacks or `cmd/2` slice updates.

  ## ⚠️ WARNING: {:stop, ...} Semantics

  `{:stop, reason}` is a **hard stop** that terminates the AgentServer
  immediately:

  - **Remaining directives are dropped** - Any directives in the same batch will NOT be executed
  - **Async work is orphaned** - In-flight tasks may complete but their signals go nowhere
  - **Hooks don't run** - `on_after_cmd/3` and similar callbacks will NOT be invoked
  - **State may be incomplete** - External pollers may see partial state or get `:noproc`

  ### When to use `{:stop, ...}`

  Reserved for **abnormal or framework-level termination only**:

  - Irrecoverable errors during directive execution
  - Framework decisions (e.g., `on_parent_death: :stop`)
  - Explicit shutdown requests (with reason like `:shutdown`)

  ### Do NOT use `{:stop, ...}` for normal completion

  For agents that complete their work (e.g., ReAct finishing a conversation):

  1. Set `state.status` to `:completed` or `:failed` in your agent/strategy
  2. Store results in state (e.g., `last_answer`, `final_result`)
  3. Let external code poll `AgentServer.state/1` and check status
  4. Process stays alive until explicitly stopped or supervised

  This matches Elm/Redux semantics where completion is a **state concern**,
  not a process lifecycle concern.

  ## Example Implementation

      defimpl Jido.AgentServer.DirectiveExec, for: MyApp.Directive.CallLLM do
        def exec(%{model: model, prompt: prompt}, _input_signal, state) do
          agent_pid = self()

          Task.Supervisor.start_child(Jido.TaskSupervisor, fn ->
            result = MyApp.LLM.call(model, prompt)

            signal =
              Jido.Signal.new!(
                "myapp.llm.replied",
                %{model: model, result: result},
                source: "/agent/\#{state.id}"
              )

            Jido.AgentServer.cast(agent_pid, signal)
          end)

          :ok
        end
      end

  The agent then declares a `signal_routes` entry mapping
  `"myapp.llm.replied"` to an action that sets the appropriate slice
  fields (e.g., `:llm_status => :success`, `:result => result`) via its
  return value. The directive does the I/O; the action does the state
  mutation.

  ## Fallback for Unknown Directives

  Unknown directive types are logged and ignored by default. The fallback
  implementation uses `@fallback_to_any true`.
  """

  @fallback_to_any true

  @doc """
  Execute a directive.

  ## Parameters

  - `directive` - The directive struct to execute
  - `input_signal` - The signal that triggered this directive
  - `state` - The current AgentServer.State (read-only — directives may
    inspect any field but cannot return a mutated version)

  ## Returns

  - `:ok` - Continue processing
  - `{:stop, reason}` - Hard-stop the agent (see warnings above)
  """
  @spec exec(struct(), Jido.Signal.t(), Jido.AgentServer.State.t()) ::
          :ok | {:stop, term()}
  def exec(directive, input_signal, state)
end
