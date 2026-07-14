defmodule Jido.Ash.Slice.PayloadField do
  @moduledoc """
  Derived signal-payload field metadata for an Ash-backed Jido slice.
  """

  alias Jido.Ash.Slice.StateField

  @type source :: :argument | :attribute

  @type t :: %__MODULE__{
          name: atom(),
          source: source(),
          type: term(),
          allow_nil?: boolean(),
          public?: boolean(),
          default: StateField.default(),
          description: String.t() | nil,
          constraints: keyword()
        }

  defstruct [
    :name,
    :source,
    :type,
    :allow_nil?,
    :public?,
    :default,
    :description,
    :constraints
  ]

  @doc false
  @spec from_argument(argument :: Ash.Resource.Actions.Argument.t()) :: t()
  def from_argument(argument) do
    %__MODULE__{
      name: argument.name,
      source: :argument,
      type: argument.type,
      allow_nil?: argument.allow_nil?,
      public?: argument.public?,
      default: default(argument.default),
      description: argument.description,
      constraints: argument.constraints || []
    }
  end

  @doc false
  @spec from_attribute(attribute :: Ash.Resource.Attribute.t()) :: t()
  def from_attribute(attribute) do
    %__MODULE__{
      name: attribute.name,
      source: :attribute,
      type: attribute.type,
      allow_nil?: attribute.allow_nil?,
      public?: attribute.public?,
      default: default(attribute.default),
      description: attribute.description,
      constraints: attribute.constraints || []
    }
  end

  defp default(nil), do: :none
  defp default(default) when is_function(default), do: :dynamic
  defp default(default), do: {:static, default}
end
