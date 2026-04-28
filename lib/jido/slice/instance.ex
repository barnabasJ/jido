defmodule Jido.Slice.Instance do
  @moduledoc """
  Represents a normalized slice instance attached to an agent via the
  framework's `slices:` option.

  Parallel to `Jido.Plugin.Instance` but for bare slices (`use Jido.Slice`
  without a middleware half). Differences from `Plugin.Instance`:

  - No `route_prefix` field. Bare slices register their `signal_routes/0`
    at the agent with **absolute** paths — `slices:` does not prefix.
  - The `as:` field is reserved for a future multi-instance design but
    not wired in v1. Always `nil` today.

  ## Fields

  - `module` - The slice module (`use Jido.Slice`)
  - `as` - Reserved for future multi-instance support (always `nil` in v1)
  - `config` - Resolved config map (validated through `config_schema/0` if
    declared by the slice; otherwise stored verbatim)
  - `manifest` - The slice's `manifest/0` struct
  - `path` - The slice's `path/0` (no derivation in v1)
  """

  alias Jido.Plugin.Config

  @schema Zoi.struct(
            __MODULE__,
            %{
              module: Zoi.atom(description: "The slice module"),
              as:
                Zoi.atom(description: "Reserved for future multi-instance use; always nil in v1")
                |> Zoi.optional(),
              config: Zoi.map(description: "Resolved configuration") |> Zoi.default(%{}),
              manifest: Zoi.any(description: "The slice's manifest struct"),
              path: Zoi.atom(description: "The slice key in agent.state")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Instance."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds an Instance from a slice declaration.

  Accepted shapes:

  - `Module` - bare slice with no config
  - `{Module, %{key: value}}` - slice with map config
  - `{Module, [key: value]}` - slice with keyword config

  Config is resolved through `Jido.Plugin.Config.resolve_config!/2`, which
  merges any `Application.get_env(otp_app, module)` config underneath the
  caller's overrides and validates against the slice's `config_schema/0` if
  one is declared.

  Raises `ArgumentError` when the resolved config fails schema validation.
  """
  @spec new(module() | {module(), map() | keyword()}) :: t()
  def new(declaration) do
    {module, overrides} = normalize_declaration(declaration)

    manifest = module.manifest()
    resolved_config = Config.resolve_config!(module, overrides)

    %__MODULE__{
      module: module,
      as: nil,
      config: resolved_config,
      manifest: manifest,
      path: manifest.path
    }
  end

  @doc """
  Expands the slice's signal routes for the agent's combined route table.

  Bare slices register their `signal_routes/0` with **absolute** paths — no
  plugin-style `route_prefix` is applied. The output shape matches the
  3-tuple format `Jido.Plugin.Routes.detect_conflicts/1` expects.
  """
  @spec expand_routes(t()) :: [tuple()]
  def expand_routes(%__MODULE__{manifest: manifest}) do
    routes = manifest.signal_routes || []
    Enum.map(routes, &normalize_route/1)
  end

  defp normalize_route({path, target}), do: {path, target, []}
  defp normalize_route({path, target, opts}) when is_list(opts), do: {path, target, opts}

  defp normalize_route({path, target, priority}) when is_integer(priority) do
    {path, target, [priority: priority]}
  end

  defp normalize_declaration(module) when is_atom(module) do
    {module, %{}}
  end

  defp normalize_declaration({module, overrides}) when is_map(overrides) do
    {module, overrides}
  end

  defp normalize_declaration({module, overrides}) when is_list(overrides) do
    {module, Map.new(overrides)}
  end
end
