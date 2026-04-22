defprotocol Jido.AgentServer.DirectiveExec do
  @moduledoc """
  Protocol for executing directives in AgentServer.

  Implement this protocol for custom directive types to extend AgentServer
  with new effect handlers without modifying core code.

  ## Return Values

  - `{:ok, state}` - Directive executed successfully, continue processing
  - `{:stop, reason, state}` - **Hard stop** the agent process (see warning below)

  ### The async pattern

  There is no special `{:async, ...}` return. If a directive needs to do
  work that could block the GenServer, it should:

  1. Spawn a supervised task for the side-effect
  2. Record the in-flight work as a loading marker in agent state
  3. Return `{:ok, state_with_loading_marker}`
  4. When the task finishes, emit a **signal** back to the agent — the
     signal routes through the normal pipeline and its `cmd/2` clause
     settles the loading marker into `:success` or `:error`

  Signals are the single coordination vehicle, both for external input
  and for async-completion results. The state path where the loading
  marker lives is the correlation key — no separate ref tracking needed.

  ## ⚠️ WARNING: {:stop, ...} Semantics

  `{:stop, reason, state}` is a **hard stop** that terminates the AgentServer immediately:

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

          {:ok, put_in(state.agent.state.__domain__.llm_status, :loading)}
        end
      end

  ## Fallback for Unknown Directives

  Unknown directive types are logged and ignored by default. The fallback
  implementation uses `@fallback_to_any true`.
  """

  @fallback_to_any true

  @doc """
  Execute a directive, returning an updated state.

  ## Parameters

  - `directive` - The directive struct to execute
  - `input_signal` - The signal that triggered this directive
  - `state` - The current AgentServer.State

  ## Returns

  - `{:ok, state}` - Continue processing with updated state
  - `{:stop, reason, state}` - Stop the agent
  """
  @spec exec(struct(), Jido.Signal.t(), Jido.AgentServer.State.t()) ::
          {:ok, Jido.AgentServer.State.t()}
          | {:stop, term(), Jido.AgentServer.State.t()}
  def exec(directive, input_signal, state)
end
