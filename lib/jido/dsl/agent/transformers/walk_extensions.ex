defmodule Jido.Dsl.Agent.Transformers.WalkExtensions do
  @moduledoc """
  Walks the user's `extensions: […]` keyword list (recorded by
  `Jido.Agent.__using__/1` as `:jido_user_extensions`), classifies each
  entry by marker (plugin / slice / middleware), and produces the same
  internal `:plugin_instances` / `:slice_instances` / `:middleware_list`
  lists today's `__quoted_compile_instances__/0` builds.

  Order in `extensions: […]` becomes the middleware-chain order for any
  middleware halves contributed by plugins and bare-middleware modules
  (slice entries do not participate in the chain).
  """

  use Spark.Dsl.Transformer

  alias Jido.Plugin.Instance, as: PluginInstance
  alias Jido.Slice.Instance, as: SliceInstance
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    user_extensions = Transformer.get_persisted(dsl_state, :jido_user_extensions, [])
    default_slice_list = resolve_default_slices(dsl_state)

    classified =
      Enum.map(user_extensions, &classify/1)

    plugin_instances = collect(classified, :plugin)
    middleware_list = collect(classified, :middleware)
    slice_instances_from_user = collect(classified, :slice)

    default_slice_instances =
      Enum.map(default_slice_list, &SliceInstance.new/1)

    slice_instances = default_slice_instances ++ slice_instances_from_user

    plugin_specs =
      Enum.map(plugin_instances, fn instance ->
        spec = instance.module.plugin_spec(instance.config)
        %{spec | path: instance.path}
      end)

    slice_pseudo_specs =
      Enum.map(slice_instances, fn instance ->
        %{path: instance.path, schema: instance.manifest.schema}
      end)

    plugin_paths = Enum.map(plugin_instances, & &1.path)
    slice_paths = Enum.map(slice_instances, & &1.path)

    plugin_actions =
      ((plugin_specs |> Enum.flat_map(& &1.actions)) ++
         (slice_instances |> Enum.flat_map(fn inst -> inst.manifest.actions || [] end)))
      |> Enum.uniq()

    dsl_state =
      dsl_state
      |> Transformer.persist(:plugin_instances, plugin_instances)
      |> Transformer.persist(:slice_instances, slice_instances)
      |> Transformer.persist(:middleware_list, middleware_list)
      |> Transformer.persist(:plugin_specs, plugin_specs)
      |> Transformer.persist(:slice_pseudo_specs, slice_pseudo_specs)
      |> Transformer.persist(:plugin_paths, plugin_paths)
      |> Transformer.persist(:slice_paths, slice_paths)
      |> Transformer.persist(:plugin_actions, plugin_actions)
      |> Transformer.persist(:default_slice_list, default_slice_list)

    {:ok, dsl_state}
  end

  defp resolve_default_slices(dsl_state) do
    jido_module = Transformer.get_persisted(dsl_state, :jido_instance_module)
    default_slices_override = Transformer.get_persisted(dsl_state, :default_slices_override)

    base_defaults =
      if jido_module != nil and function_exported?(jido_module, :__default_slices__, 0) do
        jido_module.__default_slices__()
      else
        Jido.Agent.DefaultSlices.package_defaults()
      end

    Jido.Agent.DefaultSlices.apply_agent_overrides(base_defaults, default_slices_override)
  end

  defp collect(classified, kind) do
    classified
    |> Enum.flat_map(fn
      {^kind, value} -> [value]
      _ -> []
    end)
  end

  defp classify(entry) do
    {module, opts, as_override} = normalize_entry(entry)

    ensure_module_loaded!(module)

    plugin? = function_exported?(module, :__jido_plugin__, 0)
    slice? = function_exported?(module, :__jido_slice__, 0)
    middleware? = behaves_as_middleware?(module)

    kind = pick_kind(module, plugin?, slice?, middleware?, as_override)

    case kind do
      :plugin ->
        decl = build_decl(module, opts)
        {:plugin, PluginInstance.new(decl)}

      :slice ->
        decl = build_decl(module, opts)
        {:slice, SliceInstance.new(decl)}

      :middleware ->
        opts_map = if is_map(opts), do: opts, else: Map.new(opts || [])
        {:middleware, {module, opts_map}}
    end
  end

  defp normalize_entry(module) when is_atom(module), do: {module, %{}, nil}

  defp normalize_entry({module, opts}) when is_atom(module) and is_list(opts) do
    case Keyword.get(opts, :as) do
      kind when kind in [:plugin, :slice, :middleware] ->
        {module, Keyword.delete(opts, :as), kind}

      _other ->
        # `:as` is a plugin/slice instance alias (e.g. `as: :support`), not a
        # kind override; let `Plugin.Instance.new/1` consume it.
        {module, opts, nil}
    end
  end

  defp normalize_entry({module, opts}) when is_atom(module) and is_map(opts) do
    {module, opts, nil}
  end

  defp normalize_entry(other) do
    raise CompileError,
      description:
        "Invalid extension entry: #{inspect(other)}. Expected a module or `{Module, opts}`."
  end

  defp ensure_module_loaded!(module) do
    case Code.ensure_compiled(module) do
      {:module, _} ->
        :ok

      {:error, reason} ->
        raise CompileError,
          description: "Extension #{inspect(module)} could not be compiled: #{inspect(reason)}"
    end
  end

  defp behaves_as_middleware?(module) do
    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    Jido.Middleware in behaviours
  end

  defp pick_kind(module, plugin?, slice?, middleware?, nil) do
    cond do
      plugin? -> :plugin
      slice? -> :slice
      middleware? -> :middleware
      true -> raise_no_marker(module)
    end
  end

  defp pick_kind(module, plugin?, slice?, _middleware?, :slice) do
    if slice? or plugin?,
      do: :slice,
      else: raise_override_mismatch(module, :slice, "is not a Jido.Slice")
  end

  defp pick_kind(module, plugin?, _slice?, _middleware?, :plugin) do
    if plugin?,
      do: :plugin,
      else:
        raise_override_mismatch(
          module,
          :plugin,
          "is missing __jido_plugin__/0 (not a `use Jido.Plugin` module)"
        )
  end

  defp pick_kind(module, _plugin?, _slice?, middleware?, :middleware) do
    if middleware?,
      do: :middleware,
      else: raise_override_mismatch(module, :middleware, "does not implement Jido.Middleware")
  end

  defp pick_kind(module, _, _, _, other) do
    raise CompileError,
      description:
        "Invalid `as:` override for #{inspect(module)}: #{inspect(other)}. " <>
          "Expected one of :plugin, :slice, :middleware."
  end

  defp raise_no_marker(module) do
    raise CompileError,
      description:
        "Extension #{inspect(module)} is not a Jido.Plugin, Jido.Slice, or Jido.Middleware. " <>
          "Did you forget `use Jido.Plugin`, `use Jido.Slice`, or `use Jido.Middleware`?"
  end

  defp raise_override_mismatch(module, kind, detail) do
    raise CompileError,
      description:
        "Cannot register #{inspect(module)} as #{inspect(kind)}: " <>
          "#{inspect(module)} #{detail}."
  end

  defp build_decl(module, opts) when opts == %{}, do: module
  defp build_decl(module, opts) when opts == [], do: module
  defp build_decl(module, opts), do: {module, opts}
end
