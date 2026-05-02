defmodule Jido.Directives.Stop do
  @moduledoc """
  Request that the agent process stop.

  ## Fields

  - `reason` - Reason for stopping (default: `:normal`)
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              reason: Zoi.any(description: "Reason for stopping") |> Zoi.default(:normal)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Stop."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
