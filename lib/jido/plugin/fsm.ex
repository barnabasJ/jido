defmodule Jido.Plugin.FSM do
  @moduledoc """
  Finite-state-machine slice.

  An agent declaring `plugins: [Jido.Plugin.FSM]` gains an `:fsm` slice on
  `agent.state` containing:

      %{
        state: String.t(),                                    # current state
        history: [%{from: String.t(), to: String.t()}],       # transitions, oldest first
        terminal?: boolean(),
        transitions: %{String.t() => [String.t()]},
        terminal_states: [String.t()],
        initial_state: String.t()
      }

  Transitions are driven by signals routed to `Jido.Plugin.FSM.Transition`.
  Send a `jido.fsm.transition` signal with `data: %{to: "<next_state>"}` to
  attempt a transition.

  ## Configuration

  Per-agent configuration is a map merged into the slice at
  `Agent.new/1`:

      use Jido.Agent,
        name: "my_agent",
        path: :app,
        plugins: [
          {Jido.Plugin.FSM, %{
            initial_state: "ready",
            transitions: %{
              "ready" => ["working", "done"],
              "working" => ["ready", "done", "errored"],
              "done" => [],
              "errored" => []
            },
            terminal_states: ["done", "errored"]
          }}
        ]

  The default transition map mirrors the historical FSM strategy:

      %{
        "idle" => ["processing"],
        "processing" => ["idle", "completed", "failed"],
        "completed" => ["idle"],
        "failed" => ["idle"]
      }

  with terminal states `["completed", "failed"]`.
  """

  @default_initial_state "idle"
  @default_transitions %{
    "idle" => ["processing"],
    "processing" => ["idle", "completed", "failed"],
    "completed" => ["idle"],
    "failed" => ["idle"]
  }
  @default_terminal_states ["completed", "failed"]

  use Jido.Slice,
    name: "fsm",
    path: :fsm,
    actions: [Jido.Plugin.FSM.Transition],
    signal_routes: [
      {"jido.fsm.transition", Jido.Plugin.FSM.Transition}
    ],
    schema:
      Zoi.object(%{
        state: Zoi.string() |> Zoi.optional(),
        history: Zoi.list(Zoi.any()) |> Zoi.default([]),
        terminal?: Zoi.boolean() |> Zoi.optional(),
        initial_state: Zoi.string() |> Zoi.default(@default_initial_state),
        transitions:
          Zoi.map(Zoi.string(), Zoi.list(Zoi.string()))
          |> Zoi.default(@default_transitions),
        terminal_states: Zoi.list(Zoi.string()) |> Zoi.default(@default_terminal_states)
      })
      |> Zoi.transform({__MODULE__, :seed_runtime_fields, []})

  @doc false
  def default_initial_state, do: @default_initial_state
  @doc false
  def default_transitions, do: @default_transitions
  @doc false
  def default_terminal_states, do: @default_terminal_states

  @doc false
  @spec seed_runtime_fields(map(), Zoi.Context.t() | keyword()) :: {:ok, map()}
  def seed_runtime_fields(slice, _ctx) do
    state = Map.get(slice, :state) || slice.initial_state
    terminal? = Map.get(slice, :terminal?) || state in slice.terminal_states
    {:ok, Map.merge(slice, %{state: state, terminal?: terminal?})}
  end
end
