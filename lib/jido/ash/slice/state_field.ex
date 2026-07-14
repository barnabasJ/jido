defmodule Jido.Ash.Slice.StateField do
  @moduledoc """
  Derived state-field metadata for an Ash-backed Jido slice.
  """

  @type default :: :none | {:static, term()} | :dynamic

  @type t :: %__MODULE__{
          name: atom(),
          source: atom(),
          type: term(),
          allow_nil?: boolean(),
          public?: boolean(),
          primary_key?: boolean(),
          default: default(),
          description: String.t() | nil,
          constraints: keyword()
        }

  defstruct [
    :name,
    :source,
    :type,
    :allow_nil?,
    :public?,
    :primary_key?,
    :default,
    :description,
    :constraints
  ]

  @doc false
  @spec from_attribute(attribute :: Ash.Resource.Attribute.t()) :: t()
  def from_attribute(attribute) do
    %__MODULE__{
      name: attribute.name,
      source: attribute.source,
      type: attribute.type,
      allow_nil?: attribute.allow_nil?,
      public?: attribute.public?,
      primary_key?: attribute.primary_key?,
      default: default(attribute.default),
      description: attribute.description,
      constraints: attribute.constraints || []
    }
  end

  defp default(nil), do: :none
  defp default(default) when is_function(default), do: :dynamic
  defp default(default), do: {:static, default}
end
