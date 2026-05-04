defmodule Jido.Slices.ChildBus.Directives.UnsubscribeChild do
  @moduledoc false

  @type t :: %__MODULE__{bus: atom(), sub_id: any(), tag: any()}

  @enforce_keys [:bus, :sub_id, :tag]
  defstruct bus: nil, sub_id: nil, tag: nil
end

defimpl Jido.AgentServer.DirectiveExec, for: Jido.Slices.ChildBus.Directives.UnsubscribeChild do
  @moduledoc false

  require Logger

  alias Jido.Signal.Bus
  alias Jido.Slices.ChildBus.Directives.UnsubscribeChild

  def exec(%UnsubscribeChild{} = d, _input_signal, _state) do
    case Bus.unsubscribe(d.bus, d.sub_id) do
      :ok ->
        Logger.debug("child_bus: unsubscribed #{inspect(d.tag)} sub=#{inspect(d.sub_id)}")

      {:error, reason} ->
        Logger.warning(
          "child_bus: failed to unsubscribe #{inspect(d.tag)} sub=#{inspect(d.sub_id)}: #{inspect(reason)}"
        )
    end

    :ok
  end
end
