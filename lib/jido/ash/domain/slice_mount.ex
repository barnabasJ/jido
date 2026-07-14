defmodule Jido.Ash.Domain.SliceMount do
  @moduledoc false

  @type t :: %__MODULE__{
          path: atom(),
          module: module(),
          options: map() | keyword(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:path, :module, :options, __spark_metadata__: nil]
end
