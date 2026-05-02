defmodule Jido.Directives.RunInstruction do
  @moduledoc """
  Execute a `%Jido.Instruction{}` at runtime and route the result via
  a signal. The directive does the I/O only — running the instruction
  and emitting a result signal. The state mutation that consumes the
  result happens in an action bound to `result_signal_type` via the
  agent's `signal_routes/1`.

  The framework does **not** call `cmd/2` directly from the directive
  body anymore — that crossed the directive/action boundary. Wire a
  handler:

      # in the agent
      def signal_routes(_ctx) do
        [{"myapp.async.result", MyApp.HandleAsyncResult}]
      end

      # the directive
      Directives.run_instruction(instruction,
        result_signal_type: "myapp.async.result"
      )

  ## Fields

  - `instruction` - The `%Jido.Instruction{}` to execute
  - `result_signal_type` - Type of the signal emitted with the result
    payload. The agent's `signal_routes` should bind this type to a
    handler action that sets the appropriate slice fields.
  - `meta` - Optional metadata echoed in the result payload

  The result-signal payload shape:

      %{
        status: :ok | :error,
        result: any(),     # only when :ok
        reason: any(),     # only when :error
        effects: [...],    # action's directives, only when :ok
        instruction: %Jido.Instruction{},
        meta: map()
      }
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              instruction: Zoi.any(description: "%Jido.Instruction{} to execute"),
              result_signal_type:
                Zoi.any(
                  description:
                    "Signal type used to route the execution result. Bind via signal_routes."
                ),
              meta:
                Zoi.map(Zoi.any(), Zoi.any(), description: "Optional metadata for result payload")
                |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for RunInstruction."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
