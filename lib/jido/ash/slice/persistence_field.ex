defmodule Jido.Ash.Slice.PersistenceField do
  @moduledoc """
  Derived persistence metadata for an Ash-backed Jido slice state field.
  """

  alias Jido.Ash.Slice.StateField

  @type mode :: :durable | :transient | :restored

  @type t :: %__MODULE__{
          name: atom(),
          mode: mode(),
          source: atom(),
          default: StateField.default(),
          allow_nil?: boolean()
        }

  defstruct [:name, :mode, :source, :default, :allow_nil?]

  @doc false
  @spec from_state_field(field :: StateField.t(), mode :: mode()) :: t()
  def from_state_field(%StateField{} = field, mode) do
    %__MODULE__{
      name: field.name,
      mode: mode,
      source: field.source,
      default: field.default,
      allow_nil?: field.allow_nil?
    }
  end
end
