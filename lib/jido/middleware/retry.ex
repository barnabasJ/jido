defmodule Jido.Middleware.Retry do
  @moduledoc """
  Retries signals whose pipeline returns `{:error, _}`.

  ## Configuration

    * `:max_attempts` (default `3`) — total attempts including the first.
    * `:pattern` (optional) — signal-type pattern in `Jido.Signal.Router` syntax.
      When set, only matching signals are retried; otherwise every signal that
      fails is retried.

  Use case: flaky tool calls, transient storage errors, upstream timeouts.

  Backoff and jitter are intentionally omitted in this first pass — the
  middleware retries immediately. Higher-level back-pressure belongs in a
  user-defined middleware sitting upstream of this one.

  Retry pattern-matches the chain return: it fires only on `{:error, _}`
  returns, never on `%Directive.Error{}` directives that user code emits
  for logging on the success path.
  """

  use Jido.Middleware

  alias Jido.Signal

  @impl true
  def on_signal(signal, ctx, opts, next) do
    if applies?(signal, opts) do
      max = Map.get(opts, :max_attempts, 3)
      attempt(signal, ctx, next, max)
    else
      next.(signal, ctx)
    end
  end

  defp attempt(signal, ctx, next, attempts_left) when attempts_left > 0 do
    case next.(signal, ctx) do
      {:error, _ctx, _reason} when attempts_left > 1 ->
        attempt(signal, ctx, next, attempts_left - 1)

      other ->
        other
    end
  end

  defp applies?(_signal, %{pattern: nil}), do: true

  defp applies?(%Signal{type: type}, %{pattern: pattern}) when not is_nil(pattern),
    do: Jido.Signal.Router.matches?(type, pattern)

  defp applies?(_signal, _opts), do: true
end
