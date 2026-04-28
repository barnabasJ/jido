defmodule Jido.AI.Directive.LLMCall do
  @moduledoc """
  Side-effect directive: makes one call to `ReqLLM.Generation.generate_text/3`.

  Emitted by `Jido.AI.Actions.Ask` (first turn) and `Jido.AI.Actions.ToolResult`
  (subsequent turns, once all tool results in a batch have come back).
  The executor spawns a Task under the agent's task supervisor — the Task
  is the *only* place a blocking ReqLLM call lives, so the agent process
  stays free to handle other signals.

  Outcomes are reported back as signals to the originating agent:

    * `"ai.react.llm.completed"` with `%{turn: %Jido.AI.Turn{}, request_id: id}`
      on success.
    * `"ai.react.failed"` with `%{reason: term, request_id: id}` on
      transport / API error.

  The directive struct carries everything the executor needs so it can
  run without re-reading slice state.
  """

  @type t :: %__MODULE__{
          model: ReqLLM.model_input(),
          context: ReqLLM.Context.t(),
          tools: [module()],
          request_id: String.t(),
          llm_opts: keyword()
        }

  @enforce_keys [:model, :context, :request_id]
  defstruct model: nil,
            context: nil,
            tools: [],
            request_id: nil,
            llm_opts: []
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.AI.Directive.LLMCall do
  @moduledoc false

  alias Jido.AgentServer
  alias Jido.AI.Directive.LLMCall
  alias Jido.AI.{ToolAdapter, Turn}
  alias Jido.Signal
  alias ReqLLM.Context

  @impl true
  def exec(%LLMCall{} = directive, _input_signal, state) do
    agent_pid = self()
    task_sup = Jido.task_supervisor_name(state.jido)
    source = "/agent/#{state.id}"

    {:ok, _pid} =
      Task.Supervisor.start_child(task_sup, fn ->
        run_and_dispatch(directive, agent_pid, source)
      end)

    :ok
  end

  defp run_and_dispatch(%LLMCall{} = d, agent_pid, source) do
    reqllm_tools = ToolAdapter.from_actions(d.tools)
    messages = Context.to_list(d.context)
    llm_opts = Keyword.put(d.llm_opts, :tools, reqllm_tools)

    case ReqLLM.Generation.generate_text(d.model, messages, llm_opts) do
      {:ok, response} ->
        turn = Turn.from_response(response)

        signal =
          Signal.new!("ai.react.llm.completed", %{turn: turn, request_id: d.request_id},
            source: source
          )

        _ = AgentServer.cast(agent_pid, signal)

      {:error, reason} ->
        cast_failure(agent_pid, source, d.request_id, reason)
    end
  rescue
    # Anything raised in the Task body — bad tool definition, transport
    # exception, decoder bug — must still surface as a terminal signal.
    # If we let the Task die quietly the slice stays :running forever
    # and `Jido.AI.await/2` only ever returns `{:error, :timeout}`.
    exception -> cast_failure(agent_pid, source, d.request_id, exception)
  end

  defp cast_failure(agent_pid, source, request_id, reason) do
    signal =
      Signal.new!("ai.react.failed", %{reason: reason, request_id: request_id}, source: source)

    _ = AgentServer.cast(agent_pid, signal)
  end
end
