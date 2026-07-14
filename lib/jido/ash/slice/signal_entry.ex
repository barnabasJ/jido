defmodule Jido.Ash.Slice.SignalEntry do
  @moduledoc false

  defstruct [:type, :action, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          type: String.t(),
          action: atom()
        }
end
