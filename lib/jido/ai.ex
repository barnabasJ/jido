defmodule Jido.AI do
  @moduledoc """
  Public API for ReAct agents built on `Jido.AI.ReAct`.

  Works against any `pid` whose agent attached `Jido.AI.ReAct` via
  `slices:`. The slice is the source of truth for run config (model,
  tools, system_prompt, max_iterations, llm_opts) seeded from the
  agent's `slices:` declaration; per-call opts override.

  ## API shape

  - `ask/3` — fire-and-forget launch. Synchronously sends the
    `"ai.react.ask"` signal via `Jido.AgentServer.call/4`; returns
    `{:ok, request_id}` once the run is launched, or `{:error, reason}`
    if the action rejected (e.g. `:busy`, `:no_model`). Does *not*
    subscribe to anything — observers are out-of-band.
  - `ask_sync/3` — convenience that subscribes for the terminal
    `:completed` / `:failed` transition (pre-cast, ADR 0021), launches,
    blocks on the subscription, and returns the final text.

  Anything richer than "the final answer" — streaming tokens, tool-call
  notifications, reasoning steps, intermediate slice transitions — is
  the caller's job. Set up the subscription you want via
  `Jido.AgentServer.subscribe/4` before calling `ask/3`, then receive
  the events as they arrive.

  ## Example

      defmodule MyApp.SupportAgent do
        use Jido.Agent,
          name: "support",
          slices: [
            {Jido.AI.ReAct,
              model: "anthropic:claude-haiku-4-5-20251001",
              tools: [MyApp.Actions.LookupOrder, MyApp.Actions.RefundOrder],
              system_prompt: "You are a support agent.",
              max_iterations: 5}
          ]
      end

      {:ok, pid}  = Jido.AgentServer.start_link(agent_module: MyApp.SupportAgent)
      {:ok, text} = Jido.AI.ask_sync(pid, "Refund order 42, the customer asked.")

  Per-call overrides:

      {:ok, text} =
        Jido.AI.ask_sync(pid, "Use a different model for this one",
          model: "openai:gpt-5",
          tools: [MyApp.Actions.OneOff]
        )

  Custom observation:

      {:ok, ref} =
        Jido.AgentServer.subscribe(pid, "ai.react.**", fn state ->
          {:ok, state.agent.state.ai}
        end)

      {:ok, request_id} = Jido.AI.ask(pid, "What's the status?")
      # receive {:jido_subscription, ^ref, ...} for every step

  ## ADR conformance

    * ADR 0021 — `ask_sync/2` `receive`s the subscription fire instead
      of polling state; subscribes pre-cast to close the registration
      race.
    * ADR 0022 §5 — single active run per agent; concurrent `ask/3`
      while `:running` returns the action's `{:error, :busy}` chain
      error verbatim through `Jido.AgentServer.call/4`.
  """

  @default_await_timeout 30_000

  @type opts :: [
          model: ReqLLM.model_input() | nil,
          tools: [module()] | nil,
          system_prompt: String.t() | nil,
          max_iterations: pos_integer() | nil,
          llm_opts: keyword(),
          timeout: timeout()
        ]

  @doc """
  Launch a ReAct run on `pid`. Pure fire-and-forget — does not
  subscribe. Returns `{:ok, request_id}` once the run is in flight.

  Action-level rejections (`:busy`, `:no_model`) come back through
  `call/4`'s chain-error path wrapped in the framework's standard
  error pipeline.
  """
  @spec ask(GenServer.server(), String.t(), opts()) ::
          {:ok, String.t()} | {:error, term()}
  def ask(pid, query, opts \\ []) when is_binary(query) and is_list(opts) do
    request_id = mint_request_id()
    signal = build_ask_signal(query, request_id, opts)
    launch(pid, signal, request_id)
  end

  @doc """
  Launch a ReAct run and block on the terminal transition.

  Subscribes to the slice's terminal `:completed` / `:failed` for the
  minted `request_id` *before* casting (ADR 0021), launches via
  `call/4`, then `receive`s the subscription fire. Returns
  `{:ok, text}` on completion, `{:error, reason}` on LLM failure or
  action rejection, `{:error, :timeout}` if no terminal signal arrives
  within the timeout.

  This is the convenience path for "give me the answer." For anything
  richer — streaming, tool-call notifications, intermediate state —
  subscribe yourself and call `ask/3`.
  """
  @spec ask_sync(GenServer.server(), String.t(), opts()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def ask_sync(pid, query, opts \\ []) when is_binary(query) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_await_timeout)
    request_id = mint_request_id()
    signal = build_ask_signal(query, request_id, opts)

    with {:ok, sub_ref} <- subscribe_for_terminal(pid, request_id) do
      case launch(pid, signal, request_id) do
        {:ok, ^request_id} ->
          await_terminal(sub_ref, pid, timeout)

        {:error, _} = err ->
          _ = Jido.AgentServer.unsubscribe(pid, sub_ref)
          err
      end
    end
  end

  defp mint_request_id, do: "req_" <> Jido.Util.generate_id()

  defp build_ask_signal(query, request_id, opts) do
    data = %{
      query: query,
      request_id: request_id,
      model: Keyword.get(opts, :model),
      tools: Keyword.get(opts, :tools),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_iterations: Keyword.get(opts, :max_iterations),
      llm_opts: Keyword.get(opts, :llm_opts)
    }

    Jido.Signal.new!("ai.react.ask", data)
  end

  defp launch(pid, signal, request_id) do
    case Jido.AgentServer.call(pid, signal, fn _state -> {:ok, request_id} end) do
      {:ok, ^request_id} = ok -> ok
      {:error, _} = err -> err
    end
  end

  defp await_terminal(sub_ref, pid, timeout) do
    receive do
      {:jido_subscription, ^sub_ref, %{result: {:ok, %{status: :completed, text: text}}}} ->
        {:ok, text}

      {:jido_subscription, ^sub_ref, %{result: {:ok, %{status: :failed, error: error}}}} ->
        {:error, error}
    after
      timeout ->
        _ = Jido.AgentServer.unsubscribe(pid, sub_ref)
        {:error, :timeout}
    end
  end

  defp subscribe_for_terminal(pid, request_id) do
    selector = fn state ->
      ai = state.agent.state.ai

      cond do
        ai.request_id != request_id -> :skip
        ai.status == :completed -> {:ok, %{status: :completed, text: ai.result}}
        ai.status == :failed -> {:ok, %{status: :failed, error: ai.error}}
        true -> :skip
      end
    end

    Jido.AgentServer.subscribe(pid, "**", selector, once: true)
  end
end
