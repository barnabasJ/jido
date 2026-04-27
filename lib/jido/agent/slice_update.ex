defmodule Jido.Agent.SliceUpdate do
  @moduledoc """
  Multi-slice action return value used when one action transactionally
  mutates multiple slices on the agent.

  Use sparingly — most actions own a single slice and should just return
  the new slice value. Multi-slice writes are an explicit escape hatch
  for genuinely cross-cutting actions.

  ## Usage

      def run(signal, _slice, _opts, _ctx) do
        {:ok,
         %Jido.Agent.SliceUpdate{
           slices: %{
             pod: %{topology: ..., topology_version: ..., mutation: ...},
             audit: %{last_event: ...}
           }
         },
         []}
      end

  Actions mutate state through their return value; directives are pure
  side effects.
  """

  @enforce_keys [:slices]
  defstruct [:slices]

  @type t :: %__MODULE__{slices: %{atom() => map()}}
end
