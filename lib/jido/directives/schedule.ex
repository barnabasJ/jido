defmodule Jido.Directives.Schedule do
  @moduledoc """
  Schedule a delayed message to the agent.

  The runtime will send the message back to the agent after the delay.

  ## Fields

  - `delay_ms` - Delay in milliseconds (must be >= 0)
  - `message` - Message to send after delay
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              delay_ms: Zoi.integer(description: "Delay in milliseconds") |> Zoi.min(0),
              message: Zoi.any(description: "Message to send after delay")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Schedule."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
