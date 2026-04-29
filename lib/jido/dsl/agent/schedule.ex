defmodule Jido.Dsl.Agent.Schedule do
  @moduledoc false

  defstruct [:cron, :signal_type, :data, :job_id, :timezone, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          cron: String.t(),
          signal_type: String.t(),
          data: map(),
          job_id: term() | nil,
          timezone: String.t() | nil
        }
end
