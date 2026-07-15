defmodule Jido.Ash.Slice.ReducerAdapter do
  @moduledoc false

  alias Jido.Ash.Slice.ReducerResult

  @ash_opt_keys [:actor, :authorize?, :context, :domain, :scope, :tenant, :tracer]

  @doc false
  @spec payload(signal :: Jido.Signal.t() | map()) :: map()
  def payload(%Jido.Signal{data: data}) when is_map(data), do: data
  def payload(%{} = data), do: data
  def payload(_signal), do: %{}

  @doc false
  @spec payload(signal :: Jido.Signal.t() | map(), resource :: module(), action :: atom()) ::
          map()
  def payload(signal, resource, action) do
    allowed_keys =
      resource
      |> Ash.Resource.Info.action(action)
      |> Map.fetch!(:arguments)
      |> Enum.flat_map(fn argument -> [argument.name, Atom.to_string(argument.name)] end)

    signal
    |> payload()
    |> Map.take(allowed_keys)
  end

  @doc false
  @spec ash_opts(
          ctx :: map(),
          opts :: map() | keyword(),
          slice :: map(),
          signal :: Jido.Signal.t() | map()
        ) :: keyword()
  def ash_opts(ctx, opts \\ %{}, slice \\ %{}, signal \\ %{}) do
    opts
    |> normalize_opts()
    |> Map.merge(Map.take(ctx || %{}, @ash_opt_keys))
    |> put_reducer_context(ctx || %{}, slice, signal)
    |> Map.to_list()
  end

  @doc false
  @spec to_action_result(
          result :: :ok | {:ok, term()} | {:error, term()},
          current_slice :: map()
        ) :: {:ok, map(), [Jido.Directives.t()]} | {:error, term()}
  def to_action_result(:ok, current_slice), do: {:ok, ensure_slice(current_slice), []}

  def to_action_result({:ok, result}, current_slice), do: normalize_success(result, current_slice)

  def to_action_result({:error, reason}, _current_slice), do: {:error, reason}

  defp normalize_success({:error, reason}, _current_slice), do: {:error, reason}

  defp normalize_success(%ReducerResult{slice: slice, directives: directives}, _current_slice) do
    {:ok, ensure_slice(slice), List.wrap(directives)}
  end

  defp normalize_success({slice, directives}, _current_slice) when is_map(slice) do
    {:ok, slice, List.wrap(directives)}
  end

  defp normalize_success(slice, _current_slice) when is_map(slice), do: {:ok, slice, []}

  defp normalize_success(other, _current_slice) do
    {:error, {:invalid_reducer_result, other}}
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_opts), do: %{}

  defp put_reducer_context(opts, ctx, slice, signal) do
    context =
      opts
      |> Map.get(:context, %{})
      |> Map.merge(%{jido_ctx: ctx, signal: signal, slice: ensure_slice(slice)})

    Map.put(opts, :context, context)
  end

  defp ensure_slice(slice) when is_map(slice), do: slice
  defp ensure_slice(_slice), do: %{}
end
