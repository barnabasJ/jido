defmodule Jido.Dsl.Agent.Seeder do
  @moduledoc """
  Runtime helpers invoked by the code emitted by
  `Jido.Dsl.Agent.Transformers.GenerateAccessors`. They turn user-supplied
  input + the agent's compile-time slice schemas into the validated
  initial state map for `MyAgent.new/1`.

  Two entry points:

    * `seed_own/2` — seeds the agent's *own* slice (the one declared
      inline in `agent do; path :foo; schema [...]; end`). The schema is
      passed as a literal because it isn't carried by a separate slice
      module. Supports both Zoi schemas and NimbleOptions keyword lists.

    * `seed_mount/3` — seeds a mounted slice or plugin (anything from
      `slices do … end`). The schema is looked up at runtime via
      `Jido.Dsl.Slice.Info.schema/1`. Honors the lazy-init contract:
      empty user input + missing required fields yields `nil` so an
      action (typically `Ensure`) can materialize the slice on demand.

  Validation failures raise `Jido.Agent.SliceValidationError` so the
  generated `new/1` surfaces a useful path/module in the error message.
  """

  alias Jido.Agent.SliceValidationError
  alias Jido.Agent.State
  alias Jido.Dsl.Slice.Info, as: SliceInfo

  @spec seed_own(term(), map()) :: map()
  def seed_own([], user_value), do: user_value
  def seed_own(nil, user_value), do: user_value

  def seed_own(schema, user_value) when is_list(schema) do
    defaults = State.defaults_from_schema(schema)
    Map.merge(defaults, user_value)
  end

  def seed_own(schema, user_value) do
    case Zoi.parse(schema, user_value) do
      {:ok, validated} ->
        validated

      {:error, errors} ->
        raise SliceValidationError, path: nil, module: nil, errors: errors
    end
  end

  @spec seed_mount(module(), map(), atom()) :: term()
  def seed_mount(slice_module, %{} = merged_input, mount_path)
      when is_atom(mount_path) do
    case SliceInfo.schema(slice_module) do
      nil ->
        if map_size(merged_input) == 0, do: nil, else: merged_input

      schema ->
        seed_mount_from_schema(slice_module, schema, merged_input, mount_path)
    end
  end

  defp seed_mount_from_schema(slice_module, schema, merged_input, mount_path) do
    case Zoi.parse(schema, merged_input) do
      {:ok, validated} ->
        validated

      {:error, _errors} when map_size(merged_input) == 0 ->
        nil

      {:error, errors} ->
        raise SliceValidationError,
          path: mount_path,
          module: slice_module,
          errors: errors
    end
  end
end
