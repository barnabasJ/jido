defmodule Jido.Ash.Slice.SignalPayload do
  @moduledoc """
  Derived payload metadata for a `jido_slice` signal binding.
  """

  alias Jido.Ash.Slice.PayloadField

  @type t :: %__MODULE__{
          type: String.t(),
          action: atom(),
          fields: [PayloadField.t()]
        }

  defstruct [:type, :action, fields: []]
end
