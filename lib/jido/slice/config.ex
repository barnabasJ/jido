defmodule Jido.Slice.Config do
  @moduledoc """
  Resolves and validates slice configuration.

  Config resolution merges three sources (in order of precedence):
  1. Per-agent overrides (highest priority)
  2. Application environment config (`Application.get_env(otp_app, slice_module)`)
  3. Default values from the slice's config_schema (lowest priority)
  """

  @doc """
  Resolves configuration for a slice module by merging app env with overrides.
  """
  @spec resolve_config(module(), map()) :: {:ok, map()} | {:error, list()}
  def resolve_config(slice_module, overrides \\ %{}) do
    base_config = get_app_env_config(slice_module)
    merged_config = Map.merge(base_config, overrides)

    validate_config(slice_module, merged_config)
  end

  @doc """
  Like `resolve_config/2` but raises on validation errors.
  """
  @spec resolve_config!(module(), map()) :: map()
  def resolve_config!(slice_module, overrides \\ %{}) do
    case resolve_config(slice_module, overrides) do
      {:ok, config} ->
        config

      {:error, errors} ->
        raise ArgumentError,
              "Config validation failed for #{inspect(slice_module)}: #{inspect(errors)}"
    end
  end

  @doc false
  @spec get_app_env_config(module()) :: map()
  def get_app_env_config(slice_module) do
    otp_app = Jido.Dsl.Slice.Info.otp_app(slice_module)

    if otp_app do
      Application.get_env(otp_app, slice_module, %{})
      |> normalize_to_map()
    else
      %{}
    end
  end

  defp normalize_to_map(config) when is_list(config), do: Map.new(config)
  defp normalize_to_map(config) when is_map(config), do: config
  defp normalize_to_map(_), do: %{}

  defp validate_config(slice_module, config) do
    config_schema = Jido.Dsl.Slice.Info.config_schema(slice_module)

    if config_schema do
      case Zoi.parse(config_schema, config) do
        {:ok, validated} -> {:ok, validated}
        {:error, errors} -> {:error, errors}
      end
    else
      {:ok, config}
    end
  end
end
