defmodule Jido.AI.Agent do
  @moduledoc """
  Macro that turns a user module into a signal-driven ReAct agent.

  ## Example

      defmodule MyApp.MathAgent do
        use Jido.AI.Agent,
          name: "math",
          description: "Does math.",
          model: "anthropic:claude-haiku-4-5-20251001",
          tools: [MyApp.Actions.Add, MyApp.Actions.Multiply],
          system_prompt: "You are a precise mathematician.",
          max_iterations: 6
      end

      {:ok, pid} = Jido.AgentServer.start(agent_module: MyApp.MathAgent)
      {:ok, request} = MyApp.MathAgent.ask(pid, "What is 5 + 7 * 2?")
      {:ok, "19"} = MyApp.MathAgent.await(request, timeout: 30_000)

  ## What the macro does

  Calls `use Jido.Agent` with the path, schema, and signal routes pulled
  straight off `Jido.AI.Slice`'s metadata. The agent's *own* slice is
  the AI slice — there is no plugin indirection, no extra hidden state
  key. `Jido.AI.Slice` is a slice; this macro just makes its host agent.

  Three runtime helpers are defined on the calling module:

    * `ask/3` — mints a `request_id`, registers a `subscribe/4` watcher
      tracking the slice's terminal transition, then casts an
      `"ai.react.ask"` signal. Returns `{:ok, %Jido.AI.Request{}}`.
      Subscribes **before** casting (ADR 0021's "no polling" rule). A
      pre-cast pure read of the slice's status returns
      `{:error, :busy}` if a run is already `:running`.
    * `await/2` — `receive`s the subscription message produced by
      `ask/3`. Returns `{:ok, text}` on completion, `{:error, reason}`
      on failure, `{:error, :timeout}` if no terminal signal arrives.
      Pure `receive` — no polling.
    * `ask_sync/3` — convenience that pipes `ask/3` into `await/2`.

  ## Configuration knobs

  All compile-time defaults are overridable per call via `ask/3`'s opts:
  `:model`, `:tools`, `:system_prompt`, `:max_iterations`, `:llm_opts`.
  `:llm_opts` is keyword-merged with the macro-level `:max_tokens` and
  `:temperature` defaults so callers can override only the keys they
  care about.

  ## ADR conformance

    * ADR 0017 — slice routes are declared on `Jido.AI.Slice`; the
      generated agent borrows them via `signal_routes:` rather than
      duplicating.
    * ADR 0019 — every action in the slice mutates state and (optionally)
      emits a directive; only the directive executors do I/O. The agent
      process is never blocked by an LLM call or a tool exec.
    * ADR 0021 — `await/2` `receive`s the subscription fire instead of
      polling state; `ask/3` subscribes pre-cast to close the
      registration race.
    * ADR 0022 §5 — single active run per agent; concurrent `ask/3`
      while `:running` returns `{:error, :busy}`.
  """

  @default_max_iterations 10
  @default_max_tokens 4_096
  @default_temperature 0.2
  @default_await_timeout 30_000

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "Jido.AI.Agent #{inspect(name)}")
    raw_model = Keyword.fetch!(opts, :model)
    raw_tools = Keyword.get(opts, :tools, [])
    raw_system_prompt = Keyword.get(opts, :system_prompt)
    max_iter = Keyword.get(opts, :max_iterations, @default_max_iterations)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature, @default_temperature)

    model = Jido.Agent.expand_and_eval_literal_option(raw_model, __CALLER__)
    tools = Jido.Agent.expand_and_eval_literal_option(raw_tools, __CALLER__)
    system_prompt = Jido.Agent.expand_and_eval_literal_option(raw_system_prompt, __CALLER__)

    quote location: :keep do
      use Jido.Agent,
        name: unquote(name),
        description: unquote(description),
        path: Jido.AI.Slice.path(),
        schema: Jido.AI.Slice.schema(),
        signal_routes: Jido.AI.Slice.signal_routes()

      @ai_model unquote(Macro.escape(model))
      @ai_tools unquote(tools)
      @ai_system_prompt unquote(system_prompt)
      @ai_max_iterations unquote(max_iter)
      @ai_default_llm_opts [
        max_tokens: unquote(max_tokens),
        temperature: unquote(temperature)
      ]

      @doc """
      Open a ReAct run on `pid`, returning a `%Jido.AI.Request{}` handle.

      Per-call overrides: `:model`, `:tools`, `:system_prompt`,
      `:max_iterations`, `:llm_opts`.
      """
      @spec ask(GenServer.server(), String.t(), keyword()) ::
              {:ok, Jido.AI.Request.t()} | {:error, term()}
      def ask(pid, query, opts \\ []) when is_binary(query) and is_list(opts) do
        Jido.AI.Agent.__ask__(pid, query, opts, __ai_defaults__())
      end

      @doc """
      Block on the terminal subscription registered by `ask/3`.

      Returns `{:ok, text}` on completion, `{:error, reason}` on LLM
      failure, `{:error, :timeout}` if no terminal signal arrives within
      `timeout` ms (default `#{unquote(@default_await_timeout)}`).
      """
      @spec await(Jido.AI.Request.t(), keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}
      def await(%Jido.AI.Request{} = request, opts \\ []) when is_list(opts) do
        Jido.AI.Agent.__await__(request, opts)
      end

      @doc "Pipe `ask/3` into `await/2`."
      @spec ask_sync(GenServer.server(), String.t(), keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}
      def ask_sync(pid, query, opts \\ []) do
        with {:ok, request} <- ask(pid, query, opts) do
          await(request, opts)
        end
      end

      @doc false
      def __ai_defaults__ do
        %{
          model: @ai_model,
          tools: @ai_tools,
          system_prompt: @ai_system_prompt,
          max_iterations: @ai_max_iterations,
          llm_opts: @ai_default_llm_opts
        }
      end
    end
  end

  @doc false
  @spec __ask__(GenServer.server(), String.t(), keyword(), map()) ::
          {:ok, Jido.AI.Request.t()} | {:error, term()}
  def __ask__(pid, query, opts, defaults) do
    request_id = "req_" <> Jido.Util.generate_id()

    signal_data = %{
      query: query,
      request_id: request_id,
      model: Keyword.get(opts, :model, defaults.model),
      tools: Keyword.get(opts, :tools, defaults.tools),
      system_prompt: Keyword.get(opts, :system_prompt, defaults.system_prompt),
      max_iterations: Keyword.get(opts, :max_iterations, defaults.max_iterations),
      llm_opts: Keyword.merge(defaults.llm_opts, Keyword.get(opts, :llm_opts, []))
    }

    signal = Jido.Signal.new!("ai.react.ask", signal_data)

    with {:ok, _status} <- check_not_running(pid),
         {:ok, sub_ref} <- subscribe_for_terminal(pid, request_id) do
      case Jido.AgentServer.cast(pid, signal) do
        :ok ->
          {:ok, %Jido.AI.Request{id: request_id, sub_ref: sub_ref, agent_pid: pid}}

        {:error, _} = err ->
          _ = Jido.AgentServer.unsubscribe(pid, sub_ref)
          err
      end
    end
  end

  @doc false
  @spec __await__(Jido.AI.Request.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def __await__(%Jido.AI.Request{sub_ref: sub_ref, agent_pid: pid}, opts) do
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

  # Single-active-run guard (ADR 0022 §5). The state read is a pure
  # projection — it doesn't enter the signal pipeline — so the only race
  # window is between this read and the cast below. The agent's `Ask`
  # action backstops the race by also rejecting `:running` slices, but
  # its error is not propagated through the cast path; this synchronous
  # read is what gives the caller a clean `{:error, :busy}`.
  defp check_not_running(pid) do
    case Jido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.ai.status} end) do
      {:ok, :running} -> {:error, :busy}
      {:ok, status} -> {:ok, status}
      {:error, _} = err -> err
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
