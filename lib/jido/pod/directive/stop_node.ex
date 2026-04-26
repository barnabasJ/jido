defmodule Jido.Pod.Directive.StopNode do
  @moduledoc false

  alias Jido.Pod.Mutation

  @schema Zoi.struct(
            __MODULE__,
            %{
              name:
                Zoi.union([
                  Zoi.atom(description: "Topology node name to stop."),
                  Zoi.string(description: "Topology node name to stop.")
                ]),
              reason: Zoi.any(description: "Stop reason.") |> Zoi.default(:shutdown)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new!(Mutation.node_name(), keyword() | map()) :: t()
  def new!(name, opts \\ []) do
    %__MODULE__{
      name: name,
      reason: Keyword.get(Enum.into(opts, []), :reason, :shutdown)
    }
  end
end
