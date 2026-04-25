defmodule Jido.Middleware.Retry do
  @moduledoc """
  Retries signals whose pipeline returns `%Jido.Agent.Directive.Error{}` directives.

  ## Configuration

    * `:max_attempts` (default `3`) — total attempts including the first.
    * `:pattern` (optional) — signal-type pattern in `Jido.Signal.Router` syntax.
      When set, only matching signals are retried; otherwise every signal that
      yields an error directive is retried.

  Use case: flaky tool calls, transient storage errors, upstream timeouts.

  Backoff and jitter are intentionally omitted in this first pass — the
  middleware retries immediately. Higher-level back-pressure belongs in a
  user-defined middleware sitting upstream of this one.
  """

  use Jido.Middleware

  alias Jido.Agent.Directive
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
    {_new_ctx, dirs} = result = next.(signal, ctx)

    if has_error?(dirs) and attempts_left > 1 do
      attempt(signal, ctx, next, attempts_left - 1)
    else
      result
    end
  end

  defp has_error?(dirs), do: Enum.any?(dirs, &match?(%Directive.Error{}, &1))

  defp applies?(_signal, %{pattern: nil}), do: true

  defp applies?(%Signal{type: type}, %{pattern: pattern}) when not is_nil(pattern),
    do: Jido.Signal.Router.matches?(type, pattern)

  defp applies?(_signal, _opts), do: true
end
