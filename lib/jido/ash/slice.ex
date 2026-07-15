defmodule Jido.Ash.Slice do
  @moduledoc """
  Ash resource extension for declaring a future Jido slice surface.

  This is the declaration-only layer: it records metadata and signal-to-action
  bindings on an Ash resource. Later transformers derive Jido state schemas,
  generated reducer actions, and mountable slice modules from the declarations.
  """

  alias Jido.Ash.Slice.SignalEntry
  alias Jido.Ash.Slice.PersistenceEntry

  @signal %Spark.Dsl.Entity{
    name: :signal,
    describe: "Binds a Jido signal type to an Ash action on this resource.",
    target: SignalEntry,
    args: [:type, :action],
    schema: [
      type: [type: :string, required: true],
      action: [type: :atom, required: true]
    ]
  }

  @persist %Spark.Dsl.Entity{
    name: :persist,
    describe: "Marks an Ash attribute's generated checkpoint behavior.",
    target: PersistenceEntry,
    args: [:attribute, :mode],
    schema: [
      attribute: [type: :atom, required: true],
      mode: [type: {:in, [:durable, :transient, :restored]}, required: true]
    ]
  }

  @jido_slice_section %Spark.Dsl.Section{
    name: :jido_slice,
    describe: "Ash-backed Jido slice declaration.",
    schema: [
      name: [
        type: {:custom, __MODULE__, :validate_slice_name, []},
        required: true,
        doc: "Slice name. Atoms are normalized to strings."
      ],
      description: [type: :string],
      category: [type: :string],
      vsn: [type: :string],
      otp_app: [type: :atom],
      tags: [type: {:list, :string}, default: []],
      persistence_transform: [
        type: :atom,
        doc:
          "Optional Jido.Persist.Transform module for application-specific checkpoint encoding."
      ]
    ],
    entities: [@signal, @persist]
  }

  use Spark.Dsl.Extension,
    sections: [@jido_slice_section],
    transformers: [Jido.Ash.Slice.Transformers.GenerateActionModules],
    verifiers: [
      Jido.Ash.Slice.Verifiers.SignalActionsExist,
      Jido.Ash.Slice.Verifiers.PersistenceAttributesExist
    ]

  @doc false
  @spec validate_slice_name(name :: atom() | String.t(), opts :: keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_slice_name(name, opts \\ [])

  def validate_slice_name(name, opts) when is_atom(name) do
    name
    |> Atom.to_string()
    |> validate_slice_name(opts)
  end

  def validate_slice_name(name, _opts) when is_binary(name) do
    Jido.Slice.validate_slice_name(name, [])
  end

  def validate_slice_name(_name, _opts), do: {:error, "Invalid slice name format."}
end
