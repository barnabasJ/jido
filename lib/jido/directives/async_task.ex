defmodule Jido.Directives.AsyncTask do
  @moduledoc """
  Run blocking work under the agent's task supervisor and report back by signal.

  `Spawn` is the low-level fire-and-forget primitive. Use `AsyncTask` when
  the work has a result that should re-enter the agent's normal signal routes.
  The executor starts a supervised task, normalizes the task's return value, and
  casts one or more signals back to the originating agent.

  The work may return a fully-built `%Jido.Signal{}` when it needs complete
  control over the reply envelope. Otherwise, ordinary `{:ok, value}` and
  `{:error, reason}` results are wrapped using `success_type` and `error_type`.

  ## Result normalization

      %Jido.Signal{} -> signal is cast back as-is
      {:ok, %Jido.Signal{}} -> signal is cast back as-is
      {:signals, signals} -> all signals are cast back
      {:ok, {:signals, signals}} -> all signals are cast back
      {:ok, result} -> success signal with payload + %{result: result}
      {:error, reason} -> error signal with payload + %{reason: reason}
      other -> success signal with payload + %{result: other}
  """

  @default_success_type "jido.async_task.completed"
  @default_error_type "jido.async_task.failed"

  @type work :: {module :: module(), function :: atom(), args :: [term()]} | function()
  @type target :: GenServer.server() | nil

  @schema Zoi.struct(
            __MODULE__,
            %{
              work: Zoi.any(description: "MFA or function to execute in a supervised task"),
              success_type:
                Zoi.string(description: "Signal type emitted for successful non-signal results")
                |> Zoi.default(@default_success_type),
              error_type:
                Zoi.string(
                  description: "Signal type emitted for errors, exits, throws, and crashes"
                )
                |> Zoi.default(@default_error_type),
              payload:
                Zoi.map(Zoi.any(), Zoi.any(),
                  description: "Static payload merged into reply data"
                )
                |> Zoi.default(%{}),
              source:
                Zoi.string(description: "Signal source for generated reply signals")
                |> Zoi.optional(),
              target:
                Zoi.any(
                  description: "GenServer target for reply signals; defaults to originating agent"
                )
                |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for AsyncTask."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
