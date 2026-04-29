defmodule Jido.Dsl.Slice.Transformers.GenerateAccessors do
  @moduledoc """
  Final transformer in the slice DSL pipeline.

  Reads the seven sections defined by `Jido.Dsl.Slice` and emits, into
  the user's slice / plugin module, the same compile-time accessor
  surface today's `Jido.Slice.__using__/1` macro emits — `name/0`,
  `path/0`, `actions/0`, `description/0`, `category/0`, `vsn/0`,
  `otp_app/0`, `schema/0`, `config_schema/0`, `tags/0`, `capabilities/0`,
  `singleton?/0`, `requires/0`, `signal_routes/0`, `subscriptions/0`,
  `schedules/0`, `manifest/0`, `plugin_spec/1`, `__plugin_metadata__/0`,
  plus the 16-function `defoverridable` block.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(_), do: true

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    state = collect_state(dsl_state)

    block =
      quote location: :keep do
        unquote(quoted_module_attributes(state))
        unquote(quoted_basic_accessors())
        unquote(quoted_aggregate_accessors())
        unquote(quoted_manifest_and_spec())
        unquote(quoted_overridables())
      end

    {:ok, Transformer.eval(dsl_state, [], block)}
  end

  defp collect_state(dsl_state) do
    %{
      name: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :name),
      path: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :path),
      description: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :description),
      category: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :category),
      vsn: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :vsn),
      otp_app: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :otp_app),
      schema: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :schema),
      config_schema: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :config_schema),
      tags: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :tags) || [],
      singleton: Spark.Dsl.Extension.get_opt(dsl_state, [:slice], :singleton) || false,
      actions: collect_actions(dsl_state),
      signal_routes: collect_signal_routes(dsl_state),
      subscriptions: collect_subscriptions(dsl_state),
      schedules: collect_schedules(dsl_state),
      capabilities: collect_capabilities(dsl_state),
      requires: collect_requires(dsl_state)
    }
  end

  defp collect_actions(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_entities([:actions])
    |> Enum.map(& &1.module)
  end

  defp collect_signal_routes(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_entities([:signal_routes])
    |> Enum.map(&route_tuple/1)
  end

  defp route_tuple(entry) do
    %{type: type, action: action, match: match} = entry
    opts = build_route_opts(entry)

    cond do
      is_function(match, 1) ->
        {type, match, action}

      opts == [] ->
        {type, action}

      true ->
        {type, action, opts}
    end
  end

  defp build_route_opts(entry) do
    []
    |> maybe_put(:priority, entry.priority, fn p -> is_integer(p) and p != 0 end)
    |> maybe_put(:on_conflict, entry.on_conflict, &(not is_nil(&1)))
    |> maybe_put(:static, entry.static, &(not is_nil(&1)))
    |> Enum.reverse()
  end

  defp maybe_put(opts, key, value, predicate) do
    if predicate.(value), do: [{key, value} | opts], else: opts
  end

  defp collect_subscriptions(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_entities([:subscriptions])
    |> Enum.map(fn %{sensor: sensor, config: config} ->
      if config == %{}, do: sensor, else: {sensor, config}
    end)
  end

  defp collect_schedules(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_entities([:schedules])
    |> Enum.map(&schedule_tuple/1)
  end

  defp schedule_tuple(entry) do
    opts = build_schedule_opts(entry)

    if opts == [] do
      {entry.cron, entry.action}
    else
      {entry.cron, entry.action, opts}
    end
  end

  defp build_schedule_opts(entry) do
    []
    |> maybe_put(:tz, entry.tz, &(not is_nil(&1)))
    |> maybe_put(:signal, entry.signal, &(not is_nil(&1)))
    |> maybe_put(:data, entry.data, &(is_map(&1) and map_size(&1) > 0))
    |> Enum.reverse()
  end

  defp collect_capabilities(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_entities([:capabilities])
    |> Enum.map(& &1.name)
  end

  defp collect_requires(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_entities([:requires])
    |> Enum.map(fn %{kind: kind, name: name} -> {kind, name} end)
  end

  defp quoted_module_attributes(state) do
    quote do
      @jido_slice_name unquote(state.name)
      @jido_slice_path unquote(state.path)
      @jido_slice_description unquote(state.description)
      @jido_slice_category unquote(state.category)
      @jido_slice_vsn unquote(state.vsn)
      @jido_slice_otp_app unquote(state.otp_app)
      @jido_slice_schema unquote(Macro.escape(state.schema))
      @jido_slice_config_schema unquote(Macro.escape(state.config_schema))
      @jido_slice_tags unquote(Macro.escape(state.tags))
      @jido_slice_singleton unquote(state.singleton)
      @jido_slice_actions unquote(Macro.escape(state.actions))
      @jido_slice_signal_routes unquote(Macro.escape(state.signal_routes))
      @jido_slice_subscriptions unquote(Macro.escape(state.subscriptions))
      @jido_slice_schedules unquote(Macro.escape(state.schedules))
      @jido_slice_capabilities unquote(Macro.escape(state.capabilities))
      @jido_slice_requires unquote(Macro.escape(state.requires))
    end
  end

  defp quoted_basic_accessors do
    quote do
      @doc "Returns the slice's name."
      @spec name() :: String.t()
      def name, do: @jido_slice_name

      @doc "Returns the flat slice key in agent.state."
      @spec path() :: atom()
      def path, do: @jido_slice_path

      @doc "Returns the slice's description."
      @spec description() :: String.t() | nil
      def description, do: @jido_slice_description

      @doc "Returns the slice's category."
      @spec category() :: String.t() | nil
      def category, do: @jido_slice_category

      @doc "Returns the slice's version."
      @spec vsn() :: String.t() | nil
      def vsn, do: @jido_slice_vsn

      @doc "Returns the OTP application for config resolution."
      @spec otp_app() :: atom() | nil
      def otp_app, do: @jido_slice_otp_app

      @doc "Returns the Zoi schema for slice state."
      @spec schema() :: term() | nil
      def schema, do: @jido_slice_schema

      @doc "Returns the Zoi schema for per-agent configuration."
      @spec config_schema() :: term() | nil
      def config_schema, do: @jido_slice_config_schema

      @doc "Returns the slice's tags."
      @spec tags() :: [String.t()]
      def tags, do: @jido_slice_tags

      @doc "Returns whether this slice is a singleton."
      @spec singleton?() :: boolean()
      def singleton?, do: @jido_slice_singleton
    end
  end

  defp quoted_aggregate_accessors do
    quote do
      @doc "Returns the list of action modules provided by this slice."
      @spec actions() :: [module()]
      def actions, do: @jido_slice_actions

      @doc "Returns the signal routes for this slice."
      @spec signal_routes() :: [tuple()]
      def signal_routes, do: @jido_slice_signal_routes

      @doc "Returns the sensor subscriptions for this slice."
      @spec subscriptions() :: [tuple() | module()]
      def subscriptions, do: @jido_slice_subscriptions

      @doc "Returns the schedules for this slice."
      @spec schedules() :: [tuple()]
      def schedules, do: @jido_slice_schedules

      @doc "Returns the capabilities provided by this slice."
      @spec capabilities() :: [atom()]
      def capabilities, do: @jido_slice_capabilities

      @doc "Returns the requirements for this slice."
      @spec requires() :: [tuple()]
      def requires, do: @jido_slice_requires
    end
  end

  defp quoted_manifest_and_spec do
    quote do
      @doc """
      Returns the slice manifest with all compile-time metadata.
      """
      @spec manifest() :: Jido.Plugin.Manifest.t()
      def manifest do
        %Jido.Plugin.Manifest{
          module: __MODULE__,
          name: name(),
          description: description(),
          category: category(),
          tags: tags(),
          vsn: vsn(),
          otp_app: otp_app(),
          capabilities: capabilities(),
          requires: requires(),
          path: path(),
          schema: schema(),
          config_schema: config_schema(),
          actions: actions(),
          signal_routes: signal_routes(),
          subscriptions: subscriptions(),
          schedules: schedules(),
          signal_patterns: [],
          singleton: singleton?()
        }
      end

      @doc """
      Returns the slice spec with optional per-agent configuration.
      """
      @spec plugin_spec(map()) :: Jido.Plugin.Spec.t()
      def plugin_spec(config \\ %{}) do
        %Jido.Plugin.Spec{
          module: __MODULE__,
          name: name(),
          path: path(),
          description: description(),
          category: category(),
          vsn: vsn(),
          schema: schema(),
          config_schema: config_schema(),
          config: config,
          signal_patterns: [],
          tags: tags(),
          actions: actions()
        }
      end

      @doc """
      Returns metadata for `Jido.Discovery` integration.
      """
      @spec __plugin_metadata__() :: map()
      def __plugin_metadata__ do
        %{
          name: name(),
          description: description(),
          category: category(),
          tags: tags()
        }
      end
    end
  end

  defp quoted_overridables do
    quote do
      defoverridable name: 0,
                     path: 0,
                     actions: 0,
                     description: 0,
                     category: 0,
                     vsn: 0,
                     otp_app: 0,
                     schema: 0,
                     config_schema: 0,
                     tags: 0,
                     capabilities: 0,
                     singleton?: 0,
                     requires: 0,
                     signal_routes: 0,
                     subscriptions: 0,
                     schedules: 0
    end
  end
end
