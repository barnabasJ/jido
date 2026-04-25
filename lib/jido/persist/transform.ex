defmodule Jido.Persist.Transform do
  @moduledoc """
  Opt-in behaviour for Slice / Plugin modules that need a custom on-disk
  shape distinct from their in-memory representation.

  `Jido.Middleware.Persister` walks every declared slice/plugin at hibernate
  and thaw time. Modules that declare `@behaviour Jido.Persist.Transform`
  have `externalize/1` applied at hibernate (to produce the serialized form,
  typically a small pointer or summary) and `reinstate/1` at thaw (to
  reconstruct the in-memory form). Modules that don't declare the behaviour
  are persisted verbatim.

  Both callbacks are mandatory when the behaviour is declared.
  """

  @doc """
  Called on hibernate. Receives the current slice value at
  `agent.state[mod.path()]`. Returns the value to serialize. Side effects
  (e.g., flushing a journal) run synchronously inside this function.
  """
  @callback externalize(slice_value :: term()) :: term()

  @doc """
  Called on thaw. Receives whatever `externalize/1` returned at the previous
  hibernate (rehydrated by the storage adapter's decoder). Returns the full
  slice value to place at `agent.state[mod.path()]`.
  """
  @callback reinstate(stored_value :: term()) :: term()
end
