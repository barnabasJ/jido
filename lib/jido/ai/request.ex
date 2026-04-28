defmodule Jido.AI.Request do
  @moduledoc """
  Handle returned by `Jido.AI.Agent.ask/3`.

  Carries everything `await/2` needs to receive the terminal subscription
  fire and identify it: the `id` (correlation), the `sub_ref` (Erlang
  reference returned by `Jido.AgentServer.subscribe/4`), and the
  `agent_pid` (so a caller could `unsubscribe/2` on early exit).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          sub_ref: reference(),
          agent_pid: pid()
        }

  @enforce_keys [:id, :sub_ref, :agent_pid]
  defstruct [:id, :sub_ref, :agent_pid]
end
