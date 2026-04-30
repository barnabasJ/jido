defmodule Jido.Dsl.Slice.Info do
  @moduledoc """
  Introspection surface for `use Jido.Slice` modules.

  Each accessor takes the slice module and reads a field from the slice's
  Spark `dsl_state`. Replaces the per-slice hand-rolled accessor surface
  (`MyModule.name/0`, `MyModule.path/0`, …) that the
  `GenerateAccessors` transformer used to emit.

  Entity-bearing sections expose the same tuple shape today's
  `signal_routes/0` / `subscriptions/0` / `schedules/0` /
  `capabilities/0` / `requires/0` accessors return; `actions/1` is
  derived from the route table (`Enum.uniq` of route action targets) on
  each call.
  """

  alias Spark.Dsl.Extension

  @section [:slice]

  @doc "Returns the slice's name."
  @spec name(module()) :: String.t() | nil
  def name(module), do: Extension.get_opt(module, @section, :name)

  @doc "Returns the slice's description."
  @spec description(module()) :: String.t() | nil
  def description(module), do: Extension.get_opt(module, @section, :description)

  @doc "Returns the slice's category."
  @spec category(module()) :: String.t() | nil
  def category(module), do: Extension.get_opt(module, @section, :category)

  @doc "Returns the slice's version."
  @spec vsn(module()) :: String.t() | nil
  def vsn(module), do: Extension.get_opt(module, @section, :vsn)

  @doc "Returns the OTP application for config resolution."
  @spec otp_app(module()) :: atom() | nil
  def otp_app(module), do: Extension.get_opt(module, @section, :otp_app)

  @doc "Returns the Zoi schema for slice state."
  @spec schema(module()) :: term() | nil
  def schema(module), do: Extension.get_opt(module, @section, :schema)

  @doc "Returns the Zoi schema for per-agent configuration."
  @spec config_schema(module()) :: term() | nil
  def config_schema(module), do: Extension.get_opt(module, @section, :config_schema)

  @doc "Returns the slice's tags."
  @spec tags(module()) :: [String.t()]
  def tags(module), do: Extension.get_opt(module, @section, :tags) || []

  @doc "Returns the signal routes for this slice as `{type, action[, opts]}` tuples."
  @spec signal_routes(module()) :: [tuple()]
  def signal_routes(module) do
    module
    |> Extension.get_entities([:signal_routes])
    |> Enum.map(&route_tuple/1)
  end

  @doc "Returns the sensor subscriptions for this slice."
  @spec subscriptions(module()) :: [module() | {module(), map()}]
  def subscriptions(module) do
    module
    |> Extension.get_entities([:subscriptions])
    |> Enum.map(fn %{sensor: sensor, config: config} ->
      if config == %{}, do: sensor, else: {sensor, config}
    end)
  end

  @doc "Returns the schedules for this slice as `{cron, action[, opts]}` tuples."
  @spec schedules(module()) :: [tuple()]
  def schedules(module) do
    module
    |> Extension.get_entities([:schedules])
    |> Enum.map(&schedule_tuple/1)
  end

  @doc "Returns the capabilities provided by this slice."
  @spec capabilities(module()) :: [atom()]
  def capabilities(module) do
    module
    |> Extension.get_entities([:capabilities])
    |> Enum.map(& &1.name)
  end

  @doc "Returns the requirements for this slice as `{kind, name}` tuples."
  @spec requires(module()) :: [{atom(), atom() | String.t()}]
  def requires(module) do
    module
    |> Extension.get_entities([:requires])
    |> Enum.map(fn %{kind: kind, name: name} -> {kind, name} end)
  end

  @doc """
  Returns the deduplicated list of action modules referenced by this
  slice's signal routes.
  """
  @spec actions(module()) :: [module()]
  def actions(module) do
    module
    |> Extension.get_entities([:signal_routes])
    |> Enum.map(& &1.action)
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
  end

  defp route_tuple(entry) do
    %{type: type, action: action, match: match} = entry
    opts = build_route_opts(entry)

    cond do
      is_function(match, 1) -> {type, match, action}
      opts == [] -> {type, action}
      true -> {type, action, opts}
    end
  end

  defp build_route_opts(entry) do
    []
    |> maybe_put(:priority, entry.priority, fn p -> is_integer(p) and p != 0 end)
    |> maybe_put(:on_conflict, entry.on_conflict, &(not is_nil(&1)))
    |> maybe_put(:static, entry.static, &(not is_nil(&1)))
    |> Enum.reverse()
  end

  defp schedule_tuple(entry) do
    opts = build_schedule_opts(entry)
    if opts == [], do: {entry.cron, entry.action}, else: {entry.cron, entry.action, opts}
  end

  defp build_schedule_opts(entry) do
    []
    |> maybe_put(:tz, entry.tz, &(not is_nil(&1)))
    |> maybe_put(:signal, entry.signal, &(not is_nil(&1)))
    |> maybe_put(:data, entry.data, &(is_map(&1) and map_size(&1) > 0))
    |> Enum.reverse()
  end

  defp maybe_put(opts, key, value, predicate) do
    if predicate.(value), do: [{key, value} | opts], else: opts
  end
end
