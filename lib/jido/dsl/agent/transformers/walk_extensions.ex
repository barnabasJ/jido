defmodule Jido.Dsl.Agent.Transformers.WalkExtensions do
  @moduledoc """
  Reads the agent's `slices do … end` section + `middleware:` opt and
  produces the runtime instance lists agent introspection consumes:

    * `:slice_instances` — bare-slice mounts (`use Jido.Slice` modules).
    * `:plugin_instances` — plugin mounts (`use Jido.Plugin` modules).
    * `:middleware_list` — ordered middleware (from `middleware: […]`).
    * `:slice_path_for_action` — compile-time lookup
      `%{action_module => mount_path}` so `cmd/2` can route an action's
      return value to the correct slice without per-action `path :foo`
      declarations.

  The mount path comes **from the agent's `slices do …` block**, not
  from the slice's own DSL — slices/plugins no longer carry a `path`
  field.

  When a slice contributes a typed DSL section to the host (the
  `Jido.Slice.Extension` host-section mechanism, e.g. `react do … end`),
  this transformer merges the contributed-block opts into the slice's
  config map.
  """

  use Spark.Dsl.Transformer

  alias Jido.Dsl.Agent.SliceMount
  alias Jido.Dsl.Plugin.Info, as: PluginInfo
  alias Jido.Dsl.Slice.Info, as: SliceInfo
  alias Jido.Plugin.Instance, as: PluginInstance
  alias Jido.Plugin.Spec
  alias Jido.Slice.Instance, as: SliceInstance
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    user_mounts = Transformer.get_entities(dsl_state, [:slices])
    user_middleware = Transformer.get_persisted(dsl_state, :jido_user_middleware, [])
    default_slice_list = resolve_default_slices(dsl_state)

    classified_user = Enum.map(user_mounts, &classify_mount(&1, dsl_state))

    plugin_instances_from_user = collect(classified_user, :plugin)
    slice_instances_from_user = collect(classified_user, :slice)

    default_slice_instances =
      Enum.map(default_slice_list, &normalize_default_slice/1)

    plugin_instances = plugin_instances_from_user
    slice_instances = default_slice_instances ++ slice_instances_from_user

    middleware_list = Enum.map(user_middleware, &normalize_middleware!/1)

    plugin_specs = Enum.map(plugin_instances, &build_plugin_spec/1)

    slice_pseudo_specs =
      Enum.map(slice_instances, fn instance ->
        %{path: instance.path, schema: SliceInfo.schema(instance.module)}
      end)

    plugin_paths = Enum.map(plugin_instances, & &1.path)
    slice_paths = Enum.map(slice_instances, & &1.path)

    plugin_actions =
      ((plugin_specs |> Enum.flat_map(& &1.actions)) ++
         (slice_instances |> Enum.flat_map(fn inst -> SliceInfo.actions(inst.module) end)))
      |> Enum.uniq()

    slice_path_for_action =
      build_action_path_table(plugin_instances, slice_instances)

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
      |> Transformer.persist(:slice_path_for_action, slice_path_for_action)
      |> Transformer.persist(:default_slice_list, default_slice_list)

    {:ok, dsl_state}
  end

  defp build_plugin_spec(%PluginInstance{module: module, config: config, path: path}) do
    %Spec{
      module: module,
      name: PluginInfo.name(module),
      path: path,
      description: PluginInfo.description(module),
      category: PluginInfo.category(module),
      vsn: PluginInfo.vsn(module),
      schema: PluginInfo.schema(module),
      config_schema: PluginInfo.config_schema(module),
      config: config,
      signal_patterns: [],
      tags: PluginInfo.tags(module),
      actions: PluginInfo.actions(module)
    }
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

  defp normalize_default_slice(entry) do
    path = Jido.Agent.DefaultSlices.path_of(entry)
    module = Jido.Agent.DefaultSlices.module_of(entry)
    config = Jido.Agent.DefaultSlices.config_of(entry)
    ensure_module_loaded!(module)
    SliceInstance.new({module, config}, path)
  end

  defp normalize_middleware!(module) when is_atom(module) do
    ensure_module_loaded!(module)

    if middleware_eligible?(module) do
      {module, %{}}
    else
      raise CompileError,
        description:
          "Middleware module #{inspect(module)} does not implement the " <>
            "`Jido.Middleware` behaviour. Add `@behaviour Jido.Middleware` " <>
            "or move it out of the top-level `middleware: […]` list."
    end
  end

  defp normalize_middleware!({module, opts}) when is_atom(module) do
    ensure_module_loaded!(module)

    if middleware_eligible?(module) do
      {module, normalize_to_map(opts)}
    else
      raise CompileError,
        description:
          "Middleware module #{inspect(module)} does not implement the " <>
            "`Jido.Middleware` behaviour. Add `@behaviour Jido.Middleware` " <>
            "or move it out of the top-level `middleware: […]` list."
    end
  end

  defp normalize_middleware!(other) do
    raise CompileError,
      description:
        "Invalid middleware entry: #{inspect(other)}. Expected a module or `{Module, opts}`."
  end

  # A module is middleware-eligible if it explicitly declares the
  # behaviour OR is a `use Jido.Plugin` module (which adds the
  # behaviour via `handle_opts/1`).
  defp middleware_eligible?(module) do
    Spark.Dsl.is?(module, Jido.Plugin) or behaves_as_middleware?(module)
  end

  defp collect(classified, kind) do
    classified
    |> Enum.flat_map(fn
      {^kind, value} -> [value]
      _ -> []
    end)
  end

  defp classify_mount(%SliceMount{path: path, module: module, options: options}, dsl_state) do
    ensure_module_loaded!(module)

    plugin? = Spark.Dsl.is?(module, Jido.Plugin)
    slice? = Spark.Dsl.is?(module, Jido.Slice)

    if not (plugin? or slice?) do
      raise CompileError,
        description:
          "Module #{inspect(module)} mounted in `slices do …` is neither a " <>
            "`use Jido.Slice` nor a `use Jido.Plugin` module. " <>
            "Did you forget the `use` line?"
    end

    block_config = read_contributed_block(module, dsl_state)
    config = Map.merge(normalize_to_map(options), block_config)

    if plugin? do
      {:plugin, PluginInstance.new({module, config}, path)}
    else
      {:slice, SliceInstance.new({module, config}, path)}
    end
  end

  defp read_contributed_block(module, dsl_state) do
    contributed_sections =
      Transformer.get_persisted(dsl_state, :jido_contributed_sections, %{})

    case Map.get(contributed_sections, module) do
      nil ->
        %{}

      section_name ->
        dsl_state
        |> Map.get([section_name], Spark.Dsl.Extension.default_section_config())
        |> Map.get(:opts)
        |> Kernel.||([])
        |> Map.new()
    end
  end

  defp ensure_module_loaded!(module) do
    with {:module, _} <- Code.ensure_compiled(module),
         {:module, _} <- Code.ensure_loaded(module) do
      :ok
    else
      {:error, reason} ->
        raise CompileError,
          description: "Module #{inspect(module)} could not be compiled: #{inspect(reason)}"
    end
  end

  defp behaves_as_middleware?(module) do
    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    Jido.Middleware in behaviours
  end

  defp normalize_to_map(opts) when is_map(opts), do: opts
  defp normalize_to_map(opts) when is_list(opts), do: Map.new(opts)

  defp build_action_path_table(plugin_instances, slice_instances) do
    pairs =
      Enum.flat_map(plugin_instances, fn %PluginInstance{module: module, path: path} ->
        Enum.map(SliceInfo.actions(module), &{&1, path})
      end) ++
        Enum.flat_map(slice_instances, fn %SliceInstance{module: module, path: path} ->
          Enum.map(SliceInfo.actions(module), &{&1, path})
        end)

    # If two slices route to the same action module, last one wins
    # (the user picked an unusual layout — they can disambiguate by
    # giving each slice its own action module).
    Map.new(pairs)
  end
end
