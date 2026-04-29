defmodule Jido.Slice.ScheduleEntry do
  @moduledoc false

  defstruct [:cron, :action, :data, :tz, :signal, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          cron: String.t(),
          action: module(),
          data: map(),
          tz: String.t() | nil,
          signal: String.t() | nil
        }
end
