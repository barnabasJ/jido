defmodule Jido.Directives.Emit do
  @moduledoc """
  Dispatch a signal via `Jido.Signal.Dispatch`.

  The runtime interprets this directive by calling:

      Jido.Signal.Dispatch.dispatch(signal, dispatch_config)

  ## Fields

  - `signal` - A `Jido.Signal.t()` struct to dispatch
  - `dispatch` - Dispatch config: `{adapter, opts}` or list of configs
    - `:pid` - Direct to process
    - `:pubsub` - Via PubSub
    - `:bus` - To signal bus
    - `:http` / `:webhook` - HTTP endpoints
    - `:logger` / `:console` / `:noop` - Logging/testing

  If `dispatch` is omitted and the agent has no `default_dispatch`, runtime
  falls back to emitting to the current agent process (`self()`).

  ## Examples

      # Use agent's default dispatch (configured on AgentServer)
      %Emit{signal: signal}

      # Explicit dispatch to PubSub
      %Emit{signal: signal, dispatch: {:pubsub, topic: "events"}}

      # Multiple dispatch targets
      %Emit{signal: signal, dispatch: [
        {:pubsub, topic: "events"},
        {:logger, level: :info}
      ]}
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              signal: Zoi.any(description: "Jido.Signal.t() to dispatch"),
              dispatch:
                Zoi.any(description: "Dispatch config: {adapter, opts} or list")
                |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Emit."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
