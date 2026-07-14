defmodule Jido.Ash.Domain.Transformers.BuildAgentComposition do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Jido.Ash.Domain.SliceMount
  alias Jido.Ash.Slice.Info, as: AshSliceInfo
  alias Jido.Dsl.Slice.Info, as: SliceInfo
  alias Jido.Slice.Instance
  alias Spark.Dsl.Transformer

  @default_priority -10

  @impl Spark.Dsl.Transformer
  @spec transform(dsl_state :: map()) :: {:ok, map()} | {:error, term()}
  def transform(dsl_state) do
    slice_instances =
      dsl_state
      |> Transformer.get_entities([:jido_agent])
      |> Enum.map(&normalize_mount/1)

    actions =
      slice_instances
      |> Enum.flat_map(fn %Instance{module: module} -> SliceInfo.actions(module) end)
      |> Enum.uniq()

    routes =
      slice_instances
      |> Enum.flat_map(&Instance.expand_routes/1)
      |> normalize_routes()

    slice_paths_for_action = build_action_path_table(slice_instances)

    mount_config_map = Map.new(slice_instances, &{&1.path, &1.config})

    dsl_state =
      dsl_state
      |> Transformer.persist(:jido_agent_slice_instances, slice_instances)
      |> Transformer.persist(:jido_agent_slice_paths, Enum.map(slice_instances, & &1.path))
      |> Transformer.persist(:jido_agent_actions, actions)
      |> Transformer.persist(:jido_agent_routes, routes)
      |> Transformer.persist(:jido_agent_slice_paths_for_action, slice_paths_for_action)
      |> Transformer.persist(:jido_agent_mount_config_map, mount_config_map)

    {:ok, dsl_state}
  rescue
    error -> {:error, error}
  end

  defp normalize_mount(%SliceMount{path: path, module: module, options: options}) do
    ensure_module_loaded!(module)
    slice_module = resolve_slice_module!(module)
    Instance.new({slice_module, normalize_to_map(options)}, path)
  end

  defp resolve_slice_module!(module) do
    if Spark.Dsl.is?(module, Jido.Slice) do
      module
    else
      case AshSliceInfo.generated_slice_module(module) do
        nil ->
          raise CompileError,
            description:
              "Module #{inspect(module)} mounted in `jido_agent` is not a `use Jido.Slice` " <>
                "module or an Ash resource using `Jido.Ash.Slice`."

        slice_module ->
          ensure_module_loaded!(slice_module)
          slice_module
      end
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

  defp normalize_to_map(opts) when is_map(opts), do: opts
  defp normalize_to_map(opts) when is_list(opts), do: Map.new(opts)

  defp normalize_routes(routes) do
    Enum.map(routes, fn {path, target, opts} ->
      priority = Keyword.get(opts, :priority, @default_priority)
      {path, target, priority}
    end)
  end

  defp build_action_path_table(slice_instances) do
    slice_instances
    |> Enum.flat_map(fn %Instance{module: module, path: path} ->
      Enum.map(SliceInfo.actions(module), &{&1, path})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {action, paths} -> {action, Enum.uniq(paths)} end)
  end
end
