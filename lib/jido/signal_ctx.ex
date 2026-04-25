defmodule Jido.SignalCtx do
  @moduledoc """
  Per-signal runtime context helpers built on `Jido.Signal`'s `extensions` field.

  `signal.extensions[:jido_ctx]` is the canonical location for runtime context
  (user, trace, tenant, parent, partition, agent_id) that flows alongside a
  signal through middleware, actions, and emitted child directives.

  `Jido.Signal` lives in the `:jido_signal` dependency, so these helpers live
  here rather than on the struct itself.

  ## Example

      iex> sig = Jido.Signal.new!(%{type: "work.start", data: %{}})
      iex> sig = Jido.SignalCtx.put(sig, :trace_id, "t-1")
      iex> Jido.SignalCtx.get(sig, :trace_id)
      "t-1"
      iex> Jido.SignalCtx.ctx(sig)
      %{trace_id: "t-1"}
  """

  alias Jido.Signal

  @ctx_key :jido_ctx

  @type ctx :: map()

  @doc """
  Returns the full ctx map carried on the signal (default `%{}`).
  """
  @spec ctx(Signal.t()) :: ctx()
  def ctx(%Signal{} = signal) do
    Map.get(extensions(signal), @ctx_key, %{})
  end

  @doc """
  Replaces the entire ctx on the signal.
  """
  @spec put_ctx(Signal.t(), ctx()) :: Signal.t()
  def put_ctx(%Signal{} = signal, %{} = new_ctx) do
    put_extensions(signal, Map.put(extensions(signal), @ctx_key, new_ctx))
  end

  @doc """
  Sets a single key in the signal's ctx, creating the ctx if missing.
  """
  @spec put(Signal.t(), atom(), term()) :: Signal.t()
  def put(%Signal{} = signal, key, value) when is_atom(key) do
    put_ctx(signal, Map.put(ctx(signal), key, value))
  end

  @doc """
  Reads a key from the signal's ctx.
  """
  @spec get(Signal.t(), atom(), term()) :: term()
  def get(%Signal{} = signal, key, default \\ nil) when is_atom(key) do
    Map.get(ctx(signal), key, default)
  end

  @doc """
  Merges `additions` into the signal's ctx (right-biased).
  """
  @spec merge(Signal.t(), map()) :: Signal.t()
  def merge(%Signal{} = signal, %{} = additions) do
    put_ctx(signal, Map.merge(ctx(signal), additions))
  end

  @doc """
  Removes a key from the signal's ctx.
  """
  @spec delete(Signal.t(), atom()) :: Signal.t()
  def delete(%Signal{} = signal, key) when is_atom(key) do
    put_ctx(signal, Map.delete(ctx(signal), key))
  end

  @doc """
  Copies ctx from `source` onto `target`. If `target` already has a ctx, the
  source ctx is merged into it (target keys win).
  """
  @spec inherit(Signal.t(), Signal.t()) :: Signal.t()
  def inherit(%Signal{} = target, %Signal{} = source) do
    src = ctx(source)
    dst = ctx(target)
    put_ctx(target, Map.merge(src, dst))
  end

  defp extensions(%Signal{extensions: nil}), do: %{}
  defp extensions(%Signal{extensions: ext}) when is_map(ext), do: ext

  defp put_extensions(%Signal{} = signal, %{} = ext) do
    %{signal | extensions: ext}
  end
end
