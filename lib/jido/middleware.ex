defmodule Jido.Middleware do
  @moduledoc """
  A middleware wraps the agent's signal pipeline.

  Middleware is a single-tier construct: each middleware sits in a chain that
  wraps around a `next` continuation. To affect signal processing the
  middleware either calls `next.(signal, ctx)` (passing through to the rest
  of the chain) or returns a `{ctx, directives}` tuple directly.

  ## Callback shape

      on_signal(signal, ctx, opts, next) :: {map(), [struct()]}

  - `signal` — the triggering `Jido.Signal.t()`.
  - `ctx` — per-signal runtime context (user, trace, agent-level identity).
    Lives on `signal.extensions[:jido_ctx]` on the wire; promoted to an
    explicit argument here.
  - `opts` — the middleware's compile-time registration options. The chain
    builder closes over each middleware's `opts` at construction time so the
    callback receives the same map every invocation. A bare module
    registration produces `opts = %{}`.
  - `next` — the continuation. The middleware chooses whether (and when) to
    call `next.(signal, ctx)`; the result is `{new_ctx, directives}`.

  ## Defining middleware

      defmodule MyApp.Audit do
        use Jido.Middleware

        @impl true
        def on_signal(signal, ctx, _opts, next) do
          before = System.monotonic_time()
          {new_ctx, directives} = next.(signal, ctx)
          after_ = System.monotonic_time()
          :telemetry.execute([:my_app, :audit], %{us: after_ - before}, %{type: signal.type})
          {new_ctx, directives}
        end
      end

  Wiring middleware into the AgentServer signal pipeline lands in a later
  commit; this module only defines the contract.
  """

  @callback on_signal(
              signal :: Jido.Signal.t(),
              ctx :: map(),
              opts :: map(),
              next :: (Jido.Signal.t(), map() -> {map(), [struct()]})
            ) :: {map(), [struct()]}

  @optional_callbacks on_signal: 4

  defmacro __using__(_opts) do
    quote do
      @behaviour Jido.Middleware
    end
  end
end
