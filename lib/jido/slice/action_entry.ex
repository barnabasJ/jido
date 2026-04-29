defmodule Jido.Slice.ActionEntry do
  @moduledoc false

  defstruct [:module, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          module: module()
        }
end
