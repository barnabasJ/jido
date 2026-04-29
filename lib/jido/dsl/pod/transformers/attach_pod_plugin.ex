defmodule Jido.Dsl.Pod.Transformers.AttachPodPlugin do
  @moduledoc """
  Attaches `Jido.Pod.Plugin` (or a user-supplied replacement via
  `default_slices: %{pod: SomePlugin}`) to the pod's user-extensions
  list. Validates the resolved pod plugin advertises `path: :pod` and
  capability `:pod` so the rest of the pod runtime can rely on a known
  slice key.

  Runs before `DiscoverExtensions` / `WalkExtensions` so the pod plugin
  is processed alongside any user-supplied extensions.
  """

  use Spark.Dsl.Transformer

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
    user_extensions = Transformer.get_persisted(dsl_state, :jido_user_extensions, [])
    pod_section_plugin = Transformer.get_option(dsl_state, [:pod], :plugin)
    default_slices_override = Transformer.get_persisted(dsl_state, :default_slices_override)

    {pod_plugin_decl, remaining_default_slices} =
      resolve_pod_plugin(pod_section_plugin, default_slices_override)

    validate_pod_plugin!(pod_plugin_decl)

    dsl_state =
      dsl_state
      |> Transformer.persist(:jido_user_extensions, [pod_plugin_decl | user_extensions])
      |> Transformer.persist(:default_slices_override, remaining_default_slices)

    {:ok, dsl_state}
  end

  # `pod do plugin SomePlugin end` takes precedence over the legacy
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

    cond do
      PluginInfo.path(module) != @pod_state_key ->
        raise Spark.Error.DslError,
          message:
            "#{inspect(module)} must use path: #{inspect(@pod_state_key)} " <>
              "to replace the pod plugin.",
          path: []

      @pod_capability not in PluginInfo.capabilities(module) ->
        raise Spark.Error.DslError,
          message:
            "#{inspect(module)} must advertise capability " <>
              "#{inspect(@pod_capability)} to replace the pod plugin.",
          path: []

      true ->
        :ok
    end
  end

  defp extract_module(module) when is_atom(module), do: module
  defp extract_module({module, _opts}) when is_atom(module), do: module
end
