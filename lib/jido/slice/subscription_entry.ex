defmodule Jido.Slice.SubscriptionEntry do
  @moduledoc false

  defstruct [:sensor, :config, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          sensor: module(),
          config: map()
        }
end
