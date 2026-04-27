defmodule Jido.Middleware do
  @moduledoc """
  A middleware wraps the agent's signal pipeline.

  Middleware is a single-tier construct: each middleware sits in a chain that
  wraps around a `next` continuation. To affect signal processing the
  middleware either calls `next.(signal, ctx)` (passing through to the rest
  of the chain) or returns a tagged tuple directly.

  ## Callback shape

      on_signal(signal, ctx, opts, next) ::
        {:ok, ctx, [directive]}
        | {:error, ctx, reason}

  Both `next.(signal, ctx)` and `on_signal/4` return the same shape. The
  error tuple carries `ctx` so middleware-level state mutations
  (e.g. `Persister`'s thaw setting `ctx.agent`) commit to `state.agent`
  regardless of whether the action eventually errored. Action-level
  rollback lives inside `cmd/2`: the input agent flows back into ctx
  unchanged on error, and the framework commits that input agent (with
  any prior middleware mutations) to state. See
  [ADR 0018](../../guides/adr/0018-tagged-tuple-return-shape.md) §1.

  - `signal` — the triggering `Jido.Signal.t()`.
  - `ctx` — per-signal runtime context (user, trace, agent-level identity).
    Lives on `signal.extensions[:jido_ctx]` on the wire; promoted to an
    explicit argument here.
  - `opts` — the middleware's compile-time registration options. The chain
    builder closes over each middleware's `opts` at construction time so the
    callback receives the same map every invocation. A bare module
    registration produces `opts = %{}`.
  - `next` — the continuation. The middleware chooses whether (and when) to
    call `next.(signal, ctx)`; the result is `{:ok, new_ctx, [directive]}`
    on success or `{:error, new_ctx, reason}` on failure. Either branch
    carries an updated ctx.

  ## Defining middleware

      defmodule MyApp.Audit do
        use Jido.Middleware

        @impl true
        def on_signal(signal, ctx, _opts, next) do
          before = System.monotonic_time()
          result = next.(signal, ctx)
          after_ = System.monotonic_time()
          :telemetry.execute([:my_app, :audit], %{us: after_ - before}, %{type: signal.type})
          result
        end
      end

  Middleware that mutates ctx and post-processes can branch on both shapes:

      def on_signal(signal, ctx, _opts, next) do
        case next.(signal, ctx) do
          {:ok, ctx, dirs}    -> {:ok, post_process(ctx), dirs}
          {:error, ctx, reason} -> {:error, post_process(ctx), reason}
        end
      end
  """

  @typep result :: {:ok, map(), [Jido.Agent.Directive.t()]} | {:error, map(), term()}

  @callback on_signal(
              signal :: Jido.Signal.t(),
              ctx :: map(),
              opts :: map(),
              next :: (Jido.Signal.t(), map() -> result())
            ) :: result()

  @optional_callbacks on_signal: 4

  defmacro __using__(_opts) do
    quote do
      @behaviour Jido.Middleware
    end
  end
end
