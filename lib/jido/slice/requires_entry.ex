defmodule Jido.Slice.RequiresEntry do
  @moduledoc false

  defstruct [:kind, :name, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          kind: :config | :app | :plugin | :slice,
          name: atom() | String.t()
        }
end
