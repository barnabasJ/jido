defmodule Jido.Directives.Spawn do
  @moduledoc """
  Spawn a generic BEAM child process under the agent's supervisor.

  This is a **low-level, fire-and-forget** directive for spawning non-agent
  processes (Tasks, GenServers, etc.). The spawned process is **not tracked**
  in the agent's children map and has no parent-child relationship semantics.

  Use `SpawnAgent` instead if you need to spawn another Jido agent with:
  - Parent-child hierarchy tracking
  - Process monitoring and exit signals
  - The ability to address the parent from the child via `ctx.parent.pid`
  - Lifecycle management via `StopChild`

  ## Fields

  - `child_spec` - Supervisor child_spec for the process to spawn
  - `tag` - Optional correlation tag for logging (not used for tracking)
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              child_spec: Zoi.any(description: "Supervisor child_spec"),
              tag: Zoi.any(description: "Optional correlation tag") |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Spawn."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
