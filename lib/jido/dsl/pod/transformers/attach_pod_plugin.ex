defmodule Jido.Dsl.Pod.Transformers.AttachPodPlugin do
  @moduledoc """
  Attaches `Jido.Pod.Plugin` (or a user-supplied replacement via
  `default_slices: %{pod: SomePlugin}`) into the pod's `slices do …`
  section as a `SliceMount` at path `:pod`. Validates the resolved
  pod plugin advertises capability `:pod` so the rest of the pod
  runtime can rely on a known slice key.

  Runs before `WalkExtensions` so the pod plugin is processed
  alongside any user-supplied slice mounts.
  """

  use Spark.Dsl.Transformer

  alias Jido.Dsl.Agent.SliceMount
  alias Jido.Dsl.Plugin.Info, as: PluginInfo
  alias Jido.Pod.Plugin
  alias Spark.Dsl.Transformer

  @pod_state_key :pod
  @pod_capability :pod

  @impl Spark.Dsl.Transformer
  def before?(Jido.Dsl.Agent.Transformers.DiscoverExtensions), do: true
  def before?(Jido.Dsl.Agent.Transformers.WalkExtensions), do: true
  def before?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    pod_section_plugin = Transformer.get_option(dsl_state, [:pod], :plugin)
    default_slices_override = Transformer.get_persisted(dsl_state, :default_slices_override)

    {pod_plugin_decl, remaining_default_slices} =
      resolve_pod_plugin(pod_section_plugin, default_slices_override)

    validate_pod_plugin!(pod_plugin_decl)

    {pod_module, pod_options} = unpack_decl(pod_plugin_decl)
    pod_mount = %SliceMount{path: @pod_state_key, module: pod_module, options: pod_options}

    dsl_state
    |> Transformer.add_entity([:slices], pod_mount)
    |> Transformer.persist(:default_slices_override, remaining_default_slices)
    |> then(&{:ok, &1})
  end

  defp unpack_decl(module) when is_atom(module), do: {module, []}
  defp unpack_decl({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}

  defp unpack_decl({module, opts}) when is_atom(module) and is_map(opts) do
    {module, Map.to_list(opts)}
  end

  # `pod do plugin SomePlugin end` takes precedence over the
  # `default_slices: %{pod: ...}` keyword arg on `use Jido.Pod`.
  defp resolve_pod_plugin(plugin, default_slices_override) when not is_nil(plugin) do
    case plugin do
      false ->
        raise Spark.Error.DslError,
          message:
            "Jido.Pod requires a pod plugin under #{@pod_state_key}. " <>
              "Replace it with `pod do plugin YourPlugin end` instead of disabling it.",
          path: [:pod, :plugin]

      decl ->
        {decl, strip_pod_key(default_slices_override)}
    end
  end

  defp resolve_pod_plugin(_no_section_plugin, nil), do: {Plugin, nil}

  defp resolve_pod_plugin(_no_section_plugin, false) do
    raise Spark.Error.DslError,
      message:
        "Jido.Pod requires a pod plugin under #{@pod_state_key}. " <>
          "Cannot disable all default slices on a pod.",
      path: []
  end

  defp resolve_pod_plugin(_no_section_plugin, %{} = override) do
    case Map.fetch(override, @pod_state_key) do
      {:ok, false} ->
        raise Spark.Error.DslError,
          message:
            "Jido.Pod requires a pod plugin under #{@pod_state_key}. " <>
              "Replace it with `pod do plugin YourPlugin end` instead of disabling it.",
          path: []

      {:ok, decl} ->
        {decl, Map.delete(override, @pod_state_key)}

      :error ->
        {Plugin, override}
    end
  end

  defp strip_pod_key(nil), do: nil

  defp strip_pod_key(%{} = override) do
    case Map.delete(override, @pod_state_key) do
      empty when map_size(empty) == 0 -> nil
      remaining -> remaining
    end
  end

  defp validate_pod_plugin!(decl) do
    module = extract_module(decl)

    unless Code.ensure_loaded?(module) do
      raise Spark.Error.DslError,
        message: "Pod plugin #{inspect(module)} could not be loaded.",
        path: []
    end

    if @pod_capability not in PluginInfo.capabilities(module) do
      raise Spark.Error.DslError,
        message:
          "#{inspect(module)} must advertise capability " <>
            "#{inspect(@pod_capability)} to replace the pod plugin.",
        path: []
    end

    :ok
  end

  defp extract_module(module) when is_atom(module), do: module
  defp extract_module({module, _opts}) when is_atom(module), do: module
end
