defmodule Jido.Dsl.Agent.Route do
  @moduledoc false

  defstruct [:type, :action, :priority, :match, :static, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          type: String.t(),
          action: module() | mfa() | nil,
          priority: integer(),
          match: (any() -> boolean()) | nil,
          static: map() | nil
        }
end
