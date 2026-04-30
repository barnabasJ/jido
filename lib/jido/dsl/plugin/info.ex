defmodule Jido.Dsl.Plugin.Info do
  @moduledoc """
  Introspection surface for `use Jido.Plugin` modules.

  `Jido.Dsl.Plugin` re-exports `Jido.Dsl.Slice`'s sections, so plugin
  modules expose the same per-section options and entity tables. This
  module simply delegates to `Jido.Dsl.Slice.Info` so callers can stay
  aligned with the host kind they declare against.
  """

  alias Jido.Dsl.Slice.Info, as: SliceInfo

  defdelegate name(module), to: SliceInfo
  defdelegate description(module), to: SliceInfo
  defdelegate category(module), to: SliceInfo
  defdelegate vsn(module), to: SliceInfo
  defdelegate otp_app(module), to: SliceInfo
  defdelegate schema(module), to: SliceInfo
  defdelegate config_schema(module), to: SliceInfo
  defdelegate tags(module), to: SliceInfo
  defdelegate signal_routes(module), to: SliceInfo
  defdelegate subscriptions(module), to: SliceInfo
  defdelegate schedules(module), to: SliceInfo
  defdelegate capabilities(module), to: SliceInfo
  defdelegate requires(module), to: SliceInfo
  defdelegate actions(module), to: SliceInfo
end
