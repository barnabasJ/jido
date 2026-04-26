defmodule Jido.Pod.Directive.StartNode do
  @moduledoc false

  alias Jido.Pod.Mutation

  @schema Zoi.struct(
            __MODULE__,
            %{
              name:
                Zoi.union([
                  Zoi.atom(description: "Topology node name to start."),
                  Zoi.string(description: "Topology node name to start.")
                ]),
              initial_state:
                Zoi.map(description: "Initial state override for the node.")
                |> Zoi.optional(),
              opts:
                Zoi.map(description: "Runtime opts (max_concurrency, timeout, etc.).")
                |> Zoi.default(%{})
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
    {initial, rest} = Keyword.pop(Enum.into(opts, []), :initial_state)

    %__MODULE__{
      name: name,
      initial_state: initial,
      opts: Map.new(rest)
    }
  end
end
