defmodule Jido.Agent.DefaultSlices do
  @moduledoc """
  Resolves default slice lists for agents.

  Default slices are framework-provided singleton slices that are
  automatically attached to agents. They can be customized at three
  levels:

  1. **Package level** — Jido ships sensible defaults
  2. **Jido instance level** — `use Jido, default_slices: [...]` or app config
  3. **Agent level** — `default_slices: %{path => false | Module | {Module, config}}`

  ## Default-slice format

  Each default-slice entry is one of:

      {path, module}                # bare default
      {path, module, %{config}}     # default with seed config

  The path is **explicit per entry** — slices and plugins themselves
  no longer declare a `path` field on their own DSL (the agent's
  `slices do … end` block owns the path-to-slice binding). For
  defaults the path travels alongside the module here.

  ## Framework defaults

      [
        {:thread, Jido.Slices.Thread},
        {:identity, Jido.Slices.Identity},
        {:memory, Jido.Slices.Memory}
      ]

  ## Agent-level override

      use Jido.Agent, default_slices: %{thread: false}

  To replace a default with a custom implementation:

      use Jido.Agent, default_slices: %{thread: MyApp.CustomThreadSlice}

  Or with seed config:

      use Jido.Agent,
        default_slices: %{thread: {MyApp.CustomThreadSlice, %{max_entries: 100}}}

  Or disable all defaults:

      use Jido.Agent, default_slices: false
  """

  @package_defaults [
    {:thread, Jido.Slices.Thread},
    {:identity, Jido.Slices.Identity},
    {:memory, Jido.Slices.Memory}
  ]

  @type default_entry ::
          {atom(), module()} | {atom(), module(), map() | keyword()}

  @doc "Returns the framework's default slice list."
  @spec package_defaults() :: [default_entry()]
  def package_defaults, do: @package_defaults

  @doc """
  Resolves default slices for a Jido instance.

  This is a macro because `Application.compile_env/3` must be called in
  the module body of the caller, not inside a function.

  Priority (highest wins):
  1. Explicit `default_slices` option passed to `use Jido`
  2. App config: `config :otp_app, JidoModule, default_slices: [...]`
  3. Framework defaults
  """
  defmacro resolve_instance_defaults(otp_app, jido_module, explicit_defaults) do
    package_defaults = @package_defaults

    quote do
      if unquote(explicit_defaults) != nil do
        unquote(explicit_defaults)
      else
        app_config = Application.compile_env(unquote(otp_app), unquote(jido_module), [])
        Keyword.get(app_config, :default_slices, unquote(Macro.escape(package_defaults)))
      end
    end
  end

  @doc """
  Applies agent-level overrides to a list of default slices.

  ## Parameters

  - `defaults` — the resolved default-entry list (see `default_entry/0`)
  - `overrides` — agent-level override specification

  ## Override Shapes

  - `nil` — no overrides, use all defaults as-is
  - `false` — disable all defaults
  - `%{path => false}` — exclude the default at that path
  - `%{path => Module}` — replace with a different module
  - `%{path => {Module, config}}` — replace with module and config
  """
  @spec apply_agent_overrides([default_entry()], nil | false | map()) :: [default_entry()]
  def apply_agent_overrides(defaults, nil), do: defaults
  def apply_agent_overrides(_defaults, false), do: []

  def apply_agent_overrides(defaults, overrides) when is_map(overrides) do
    default_paths = Map.new(defaults, fn entry -> {path_of(entry), module_of(entry)} end)
    validate_override_keys!(overrides, default_paths)

    Enum.flat_map(defaults, fn entry ->
      path = path_of(entry)

      case Map.get(overrides, path) do
        nil -> [entry]
        false -> []
        replacement when is_atom(replacement) -> [{path, replacement}]
        {replacement, config} when is_atom(replacement) -> [{path, replacement, config}]
      end
    end)
  end

  @doc "Returns the path key for a default-slice entry."
  @spec path_of(default_entry()) :: atom()
  def path_of({path, _module}), do: path
  def path_of({path, _module, _config}), do: path

  @doc "Returns the module for a default-slice entry."
  @spec module_of(default_entry()) :: module()
  def module_of({_path, module}), do: module
  def module_of({_path, module, _config}), do: module

  @doc "Returns the seed config for a default-slice entry, or `%{}` if none."
  @spec config_of(default_entry()) :: map()
  def config_of({_path, _module}), do: %{}
  def config_of({_path, _module, config}) when is_map(config), do: config
  def config_of({_path, _module, config}) when is_list(config), do: Map.new(config)

  defp validate_override_keys!(overrides, default_paths) do
    invalid_keys = Map.keys(overrides) -- Map.keys(default_paths)

    if invalid_keys != [] do
      valid_keys = default_paths |> Map.keys() |> Enum.map_join(", ", &inspect/1)

      raise CompileError,
        description:
          "Invalid default_slices override keys: #{inspect(invalid_keys)}. " <>
            "Valid keys are: #{valid_keys}. " <>
            "To add new slices, declare them in `slices do … end` instead."
    end
  end
end
