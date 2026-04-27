defmodule Jido.Agent.PathConflictError do
  @moduledoc """
  Raised at `Jido.Agent.new/1` when two declared slices share the same `path:` —
  including the agent's own path colliding with a declared plugin's path.
  """

  defexception [:paths, :modules, message: "duplicate slice path"]

  @impl true
  def exception(opts) do
    paths = opts[:paths] || []
    modules = opts[:modules] || []

    message =
      "Slice path conflict: #{inspect(paths)} declared by multiple modules: " <>
        Enum.map_join(modules, ", ", &inspect/1)

    %__MODULE__{paths: paths, modules: modules, message: message}
  end
end
