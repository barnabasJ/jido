defmodule Jido.Agent.SliceValidationError do
  @moduledoc """
  Raised at `Jido.Agent.new/1` when a slice's seeded value fails schema
  validation. The exception carries the offending path, the slice module
  (or `nil` for the agent's own slice), and the underlying Zoi errors.
  """

  defexception [:path, :module, :errors, message: "slice validation failed"]

  @impl true
  def exception(opts) do
    path = opts[:path]
    module = opts[:module]
    errors = opts[:errors] || []

    label =
      cond do
        module != nil -> "slice #{inspect(module)} at path #{inspect(path)}"
        path != nil -> "slice at path #{inspect(path)}"
        true -> "agent slice"
      end

    detail =
      if function_exported?(Zoi, :prettify_errors, 1) do
        try do
          Zoi.prettify_errors(errors)
        rescue
          _ -> inspect(errors)
        end
      else
        inspect(errors)
      end

    %__MODULE__{
      path: path,
      module: module,
      errors: errors,
      message: "Slice validation failed for #{label}: #{detail}"
    }
  end
end
