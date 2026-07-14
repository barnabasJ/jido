defmodule Jido.Ash.Slice.ReducerResult do
  @moduledoc """
  Return value for Ash-backed slice reducer actions.

  Generic Ash actions used as Jido slice reducers may return this struct to make
  the next slice state and emitted directive descriptors explicit.
  """

  @type t :: %__MODULE__{
          slice: map(),
          directives: [Jido.Directives.t()]
        }

  defstruct [:slice, directives: []]

  @doc "Builds a reducer result from a next slice state and optional directives."
  @spec new(slice :: map(), directives :: [Jido.Directives.t()]) :: t()
  def new(slice, directives \\ []) when is_map(slice) and is_list(directives) do
    %__MODULE__{slice: slice, directives: directives}
  end
end
