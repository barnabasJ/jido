defmodule Jido.Slice.CapabilityEntry do
  @moduledoc false

  defstruct [:name, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom()
        }
end
