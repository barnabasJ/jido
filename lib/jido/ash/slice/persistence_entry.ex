defmodule Jido.Ash.Slice.PersistenceEntry do
  @moduledoc false

  @type mode :: :durable | :transient | :restored

  @type t :: %__MODULE__{
          attribute: atom(),
          mode: mode(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:attribute, :mode, __spark_metadata__: nil]
end
