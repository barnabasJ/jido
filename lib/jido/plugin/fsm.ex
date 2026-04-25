defmodule Jido.Plugin.FSM do
  @moduledoc """
  Finite-state-machine plugin.

  An agent declaring `plugins: [Jido.Plugin.FSM]` gains an `:fsm` slice
  on `agent.state` containing:

      %{
        state: String.t(),                        # current state
        history: [%{from: String.t(), to: String.t()}],  # transitions, oldest first
        terminal?: boolean(),
        transitions: %{String.t() => [String.t()]},
        terminal_states: [String.t()],
        initial_state: String.t()
      }

  Transitions are driven by signals routed to `Jido.Plugin.FSM.Transition`.
  Send a `jido.fsm.transition` signal with `data: %{to: "<next_state>"}`
  to attempt a transition.

  ## Configuration

  Per-agent configuration is a map:

      use Jido.Agent,
        name: "my_agent",
        path: :app,
        plugins: [
          {Jido.Plugin.FSM, %{
            initial_state: "idle",
            transitions: %{
              "idle" => ["running"],
              "running" => ["idle", "completed", "failed"],
              "completed" => [],
              "failed" => []
            },
            terminal_states: ["completed", "failed"]
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

  use Jido.Plugin,
    name: "fsm",
    state_key: :fsm,
    actions: [Jido.Plugin.FSM.Transition],
    signal_patterns: ["jido.fsm.*"],
    signal_routes: [
      {"jido.fsm.transition", Jido.Plugin.FSM.Transition}
    ],
    schema:
      Zoi.object(%{
        state: Zoi.string() |> Zoi.default(@default_initial_state),
        history: Zoi.list(Zoi.any()) |> Zoi.default([]),
        terminal?: Zoi.boolean() |> Zoi.default(false),
        initial_state: Zoi.string() |> Zoi.default(@default_initial_state),
        transitions:
          Zoi.map(Zoi.string(), Zoi.list(Zoi.string()))
          |> Zoi.default(@default_transitions),
        terminal_states: Zoi.list(Zoi.string()) |> Zoi.default(@default_terminal_states)
      })

  @doc false
  def default_initial_state, do: @default_initial_state
  @doc false
  def default_transitions, do: @default_transitions
  @doc false
  def default_terminal_states, do: @default_terminal_states

  @impl true
  def mount(_agent, config) do
    initial_state = Map.get(config, :initial_state, @default_initial_state)
    transitions = Map.get(config, :transitions, @default_transitions)
    terminal_states = Map.get(config, :terminal_states, @default_terminal_states)

    {:ok,
     %{
       state: initial_state,
       history: [],
       terminal?: initial_state in terminal_states,
       initial_state: initial_state,
       transitions: transitions,
       terminal_states: terminal_states
     }}
  end
end
