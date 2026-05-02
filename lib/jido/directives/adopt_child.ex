defmodule Jido.Directives.AdoptChild do
  @moduledoc """
  Attach an orphaned or unattached child agent to the current parent.

  This directive is the explicit reattachment path for Jido's logical
  hierarchy. It updates the live child runtime so the child can resume
  parent-directed communication via `ctx.parent`.

  Adoption is explicit. Jido does not automatically reconnect children
  when a logical parent restarts.

  Adoption updates the live runtime and the instance `Jido.RuntimeStore`
  binding, so later child restarts rehydrate the adopted parent relationship.

  ## Fields

  - `child` - Child PID or child agent id to adopt
  - `tag` - Tag for tracking this adopted child
  - `meta` - Metadata to write into the child's new parent reference
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              child: Zoi.any(description: "Child PID or child id"),
              tag: Zoi.any(description: "Tag for tracking this adopted child"),
              meta:
                Zoi.map(description: "Metadata to pass to the adopted child")
                |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for AdoptChild."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
