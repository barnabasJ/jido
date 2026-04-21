defmodule Jido.Agent.ScopedAction do
  @moduledoc """
  Thin wrapper around `Jido.Action` that declares which slice of
  `agent.state` the action owns.

  `state_key:` is required — a scoped action without a slice is a
  contradiction. Everything else is passed through to `Jido.Action`
  unchanged.

  ## What scoping does at runtime

  The agent strategy (`Jido.Agent.Strategy.Direct`) reflects on the
  action module's `state_key/0` before invoking `run/2`:

  * `ctx.state` is set to `agent.state[state_key]` (just the slice),
    not the full `agent.state`. The action physically cannot see other
    plugin slices or runtime refs.
  * `{:ok, new_slice}` is interpreted as "replace this slice with
    `new_slice`", not "deep-merge `new_slice` into full state". The
    runtime wraps it as a `%Jido.Agent.StateOp.SetPath{path: [state_key],
    value: new_slice}` directive.
  * `{:ok, new_slice, [directives]}` — same whole-slice replacement,
    plus the explicit directives from the action.

  That gives actions the Elm/Redux shape of `(slice, msg) -> new_slice`
  while preserving plugin-slice isolation by construction.

  ## Usage

      defmodule Counter.Increment do
        use Jido.Agent.ScopedAction,
          name: "increment",
          state_key: :__domain__,
          schema: [by: [type: :integer, default: 1]]

        @impl true
        def run(%{by: by}, %{state: state}) do
          # `state` is JUST the :__domain__ slice here.
          {:ok, %{state | count: state.count + by}}
        end
      end

  See ADR 0005 (`guides/adr/0005-agent-domain-as-a-state-slice.md`)
  for the design rationale.
  """

  defmacro __using__(opts) do
    {state_key, action_opts} =
      case Keyword.pop(opts, :state_key) do
        {nil, _rest} ->
          raise CompileError,
            description:
              "Jido.Agent.ScopedAction requires a :state_key option. Omit this macro and `use Jido.Action` directly for unscoped actions."

        {key, rest} when is_atom(key) ->
          {key, rest}

        {other, _rest} ->
          raise CompileError,
            description:
              "Jido.Agent.ScopedAction :state_key must be an atom, got: #{inspect(other)}"
      end

    quote do
      use Jido.Action, unquote(action_opts)

      @state_key unquote(state_key)

      @doc """
      Returns the `agent.state` slice key this action operates on.

      Consumed by `Jido.Agent.Strategy.Direct.run_instruction/3` to
      decide which subtree to pass into `ctx.state` and where to apply
      the returned slice.
      """
      @spec state_key() :: atom()
      def state_key, do: @state_key
    end
  end
end
