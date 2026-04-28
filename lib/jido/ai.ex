defmodule Jido.AI do
  @moduledoc """
  Public API for ReAct agents built on `Jido.AI.ReAct`.

  Works against any `pid` whose agent attached `Jido.AI.ReAct` via
  `slices:`. The slice is the source of truth for run config (model,
  tools, system_prompt, max_iterations, llm_opts) seeded from the
  agent's `slices:` declaration; `Jido.AI.ask/3` accepts per-call
  overrides for any of those keys.

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

      {:ok, pid}     = Jido.AgentServer.start_link(agent_module: MyApp.SupportAgent)
      {:ok, request} = Jido.AI.ask(pid, "Where is order 42?")
      {:ok, text}    = Jido.AI.await(request, timeout: 30_000)

      # or, piping ask into await:
      {:ok, text} = Jido.AI.ask_sync(pid, "Refund order 42, the customer asked.")

  Per-call overrides:

      {:ok, text} =
        Jido.AI.ask_sync(pid, "Use a different model for this one",
          model: "openai:gpt-5",
          tools: [MyApp.Actions.OneOff]
        )

  ## ADR conformance

    * ADR 0021 — `await/2` `receive`s the subscription fire instead of
      polling state; `ask/3` subscribes pre-cast to close the
      registration race.
    * ADR 0022 §5 — single active run per agent; concurrent `ask/3`
      while `:running` returns the action's `{:error, :busy}` error
      verbatim through `Jido.AgentServer.call/4`.
  """

  alias Jido.AI.Request

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
  Open a ReAct run on `pid`, returning a `%Jido.AI.Request{}` handle.

  Mints a `request_id`, registers a one-shot subscription to the slice's
  terminal transition (pre-cast, ADR 0021), then synchronously sends
  the `"ai.react.ask"` signal via `Jido.AgentServer.call/4`. The
  `Jido.AI.Actions.Ask` action is the single source of truth: it
  resolves per-call → slice fallback for run config, rejects with
  `{:error, :busy}` when a run is in flight, and rejects with
  `{:error, :no_model}` when no model is configured.

  Action errors are returned verbatim through `call/4`'s chain-error
  path, wrapped per the framework's standard error pipeline.

  Per-call overrides: `:model`, `:tools`, `:system_prompt`,
  `:max_iterations`, `:llm_opts`. Each is passed through the signal
  verbatim; the action keyword-merges per-call `:llm_opts` on top of
  the slice's stored `:llm_opts`.
  """
  @spec ask(GenServer.server(), String.t(), opts()) ::
          {:ok, Request.t()} | {:error, term()}
  def ask(pid, query, opts \\ []) when is_binary(query) and is_list(opts) do
    request_id = "req_" <> Jido.Util.generate_id()
    signal = build_ask_signal(query, request_id, opts)

    with {:ok, sub_ref} <- subscribe_for_terminal(pid, request_id),
         {:ok, :launched} <- launch(pid, signal, sub_ref) do
      {:ok, %Request{id: request_id, sub_ref: sub_ref, agent_pid: pid}}
    end
  end

  @doc """
  Block on the terminal subscription registered by `ask/3`.

  Returns `{:ok, text}` on completion, `{:error, reason}` on LLM
  failure, `{:error, :timeout}` if no terminal signal arrives within
  `timeout` ms (default `#{@default_await_timeout}`).
  """
  @spec await(Request.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def await(%Request{sub_ref: sub_ref, agent_pid: pid}, opts \\ []) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_await_timeout)

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

  @doc """
  Pipe `ask/3` into `await/2`.
  """
  @spec ask_sync(GenServer.server(), String.t(), opts()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def ask_sync(pid, query, opts \\ []) do
    with {:ok, request} <- ask(pid, query, opts) do
      await(request, opts)
    end
  end

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

  defp launch(pid, signal, sub_ref) do
    case Jido.AgentServer.call(pid, signal, fn _state -> {:ok, :launched} end) do
      {:ok, :launched} = ok ->
        ok

      {:error, reason} ->
        _ = Jido.AgentServer.unsubscribe(pid, sub_ref)
        {:error, reason}
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
