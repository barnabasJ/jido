defmodule Jido.Agent.DefaultSlices do
  @moduledoc """
  Resolves default slice lists for agents.

  Default slices are framework-provided singleton slices that are automatically
  attached to agents. They can be customized at three levels:

  1. **Package level** — Jido ships sensible defaults
  2. **Jido instance level** — `use Jido, default_slices: [...]` or app config
  3. **Agent level** — `default_slices: %{path => false | Module | {Module, config}}`

  ## Framework Defaults

  The framework provides these default slices:

      [Jido.Thread.Slice, Jido.Identity.Slice, Jido.Memory.Slice]

  ## Instance-Level Override

      # In use Jido macro
      use Jido, otp_app: :my_app, default_slices: [MyApp.CustomThreadSlice]

      # Or via app config
      config :my_app, MyApp.Jido, default_slices: [MyApp.CustomThreadSlice]

  ## Agent-Level Override

  Agents use a map keyed by the default slice's `path` atom:

      use Jido.Agent,
        name: "my_agent",
        default_slices: %{thread: false}

  To replace a default with a custom implementation:

      use Jido.Agent,
        name: "my_agent",
        default_slices: %{thread: MyApp.CustomThreadSlice}

  Or with configuration:

      use Jido.Agent,
        name: "my_agent",
        default_slices: %{thread: {MyApp.CustomThreadSlice, %{max_entries: 100}}}

  Or disable all defaults:

      use Jido.Agent, name: "bare", default_slices: false
  """

  @package_defaults [Jido.Thread.Slice, Jido.Identity.Slice, Jido.Memory.Slice]

  @doc "Returns the framework's default slice list."
  @spec package_defaults() :: [module()]
  def package_defaults, do: @package_defaults

  @doc """
  Resolves default slices for a Jido instance.

  This is a macro because `Application.compile_env/3` must be called in the
  module body of the caller, not inside a function.

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

  - `defaults` - The resolved default slice list (from instance or framework)
  - `overrides` - Agent-level override specification

  ## Override Shapes

  - `nil` — no overrides, use all defaults as-is
  - `false` — disable all defaults
  - `%{path => false}` — exclude the default slice with that path
  - `%{path => Module}` — replace with a different module
  - `%{path => {Module, config}}` — replace with module and config
  """
  @spec apply_agent_overrides([module() | {module(), map()}], nil | false | map()) ::
          [module() | {module(), map() | keyword()}]
  def apply_agent_overrides(defaults, nil), do: defaults
  def apply_agent_overrides(_defaults, false), do: []

  def apply_agent_overrides(defaults, overrides) when is_map(overrides) do
    default_paths = build_path_index(defaults)
    validate_override_keys!(overrides, default_paths)

    Enum.flat_map(defaults, fn slice_decl ->
      mod = extract_module(slice_decl)
      path = mod.path()

      case Map.get(overrides, path) do
        nil -> [slice_decl]
        false -> []
        replacement when is_atom(replacement) -> [replacement]
        {replacement, config} when is_atom(replacement) -> [{replacement, config}]
      end
    end)
  end

  defp build_path_index(defaults) do
    Enum.map(defaults, fn
      mod when is_atom(mod) -> {mod.path(), mod}
      {mod, _config} -> {mod.path(), mod}
    end)
    |> Map.new(fn {key, mod} -> {key, mod} end)
  end

  defp validate_override_keys!(overrides, default_paths) do
    invalid_keys = Map.keys(overrides) -- Map.keys(default_paths)

    if invalid_keys != [] do
      valid_keys = default_paths |> Map.keys() |> Enum.map_join(", ", &inspect/1)

      raise CompileError,
        description:
          "Invalid default_slices override keys: #{inspect(invalid_keys)}. " <>
            "Valid keys are: #{valid_keys}. " <>
            "To add new slices, use the `slices:` option instead."
    end
  end

  defp extract_module(mod) when is_atom(mod), do: mod
  defp extract_module({mod, _config}), do: mod
end
