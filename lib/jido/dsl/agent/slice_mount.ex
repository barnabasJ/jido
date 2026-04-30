defmodule Jido.Dsl.Agent.SliceMount do
  @moduledoc false

  defstruct [:path, :module, :options, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          path: atom(),
          module: module(),
          options: map() | keyword()
        }
end
