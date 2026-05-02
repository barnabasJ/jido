defmodule Jido.Directives.StopChild do
  @moduledoc """
  Request that a tracked child agent stop gracefully.

  This directive provides symmetric lifecycle control for child agents
  spawned via `SpawnAgent`. It sends a shutdown signal to the child,
  allowing it to terminate cleanly.

  The child is identified by its `tag` (the key used in `SpawnAgent`).
  If the child is not found, the directive is a no-op.

  ## Fields

  - `tag` - Tag of the child to stop (must match a key in the children map)
  - `reason` - Reason for stopping (default: `:normal`)

  ## Examples

      # Stop a worker by tag
      %StopChild{tag: :worker_1}

      # Stop with a specific reason
      %StopChild{tag: :processor, reason: :shutdown}

  ## Behavior

  The runtime sends a `jido.agent.stop` signal to the child process,
  which triggers a graceful shutdown. The child's exit will be delivered
  back to the parent as a `jido.agent.child.exit` signal.

  `SpawnAgent` children default to `restart: :transient`, so a normal
  `StopChild` shutdown removes the child instead of immediately restarting it.
  Custom reasons are wrapped as `{:shutdown, reason}` so transient children
  are still removed cleanly.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              tag: Zoi.any(description: "Tag of the child to stop"),
              reason: Zoi.any(description: "Reason for stopping") |> Zoi.default(:normal)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for StopChild."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
