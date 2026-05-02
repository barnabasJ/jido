defmodule Jido.Directives.Error do
  @moduledoc """
  Signal an error from agent command processing.

  This directive carries a `Jido.Error.t()` for consistent error handling.
  The runtime can log, emit, or handle errors based on this directive.

  ## Fields

  - `error` - A `Jido.Error.t()` struct
  - `context` - Optional atom describing error context (e.g., `:normalize`, `:instruction`)
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              error: Zoi.any(description: "Jido.Error struct"),
              context: Zoi.atom(description: "Error context") |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Error."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
