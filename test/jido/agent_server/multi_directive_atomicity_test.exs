defmodule JidoTest.AgentServer.MultiDirectiveAtomicityTest do
  @moduledoc """
  Per ADR 0019 / task 0015 (terminal cleanup), directives mutate no
  state — only `cmd/2`'s return slice and the cascade callbacks
  invoked from `process_signal/2` write to `agent.state` /
  `%AgentServer.State{}`. The "multi-directive atomicity" question
  shifts: what's interesting now is that an action returning a
  multi-key slice is committed atomically before the next signal is
  pulled from the mailbox.

  Signal A's action returns a slice with `{a: true, b: true, c: true}`.
  Signal B is cast right after. Under inline signal processing
  (ADR 0009), signal B's `cmd/2` must observe **all three keys** set —
  not a partial prefix.
  """
  use JidoTest.Case, async: true

  defmodule SetMultipleKeysAction do
    @moduledoc false
    use Jido.Action, name: "set_multiple"

    def run(_signal, slice, _opts, _ctx) do
      slice = slice || %{}
      {:ok, Map.merge(slice, %{cmd_ran: true, key_a: true, key_b: true, key_c: true}), []}
    end
  end

  defmodule ObserveAction do
    @moduledoc false
    use Jido.Action, name: "observe"

    def run(_signal, slice, _opts, _ctx) do
      slice = slice || %{}

      observation = %{
        saw_cmd: Map.get(slice, :cmd_ran, false),
        saw_a: Map.get(slice, :key_a, false),
        saw_b: Map.get(slice, :key_b, false),
        saw_c: Map.get(slice, :key_c, false)
      }

      {:ok, Map.merge(slice, observation), []}
    end
  end

  defmodule AtomicityAgent do
    @moduledoc false
    use Jido.Agent,
      name: "atomicity_agent",
      path: :domain,
      schema: [
        cmd_ran: [type: :boolean, default: false],
        key_a: [type: :boolean, default: false],
        key_b: [type: :boolean, default: false],
        key_c: [type: :boolean, default: false],
        saw_cmd: [type: :boolean, default: false],
        saw_a: [type: :boolean, default: false],
        saw_b: [type: :boolean, default: false],
        saw_c: [type: :boolean, default: false]
      ]

    def signal_routes(_ctx) do
      [
        {"set_multiple", SetMultipleKeysAction},
        {"observe", ObserveAction}
      ]
    end
  end

  describe "multi-key slice atomicity" do
    test "signal B observes every slice key set by signal A's cmd return", %{jido: jido} do
      pid = start_server(%{jido: jido}, AtomicityAgent)

      Jido.AgentServer.cast(pid, signal("set_multiple", %{}))
      Jido.AgentServer.cast(pid, signal("observe", %{}))

      domain =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.saw_c, do: s.agent.state.domain
        end)

      assert domain.cmd_ran
      assert domain.key_a
      assert domain.key_b
      assert domain.key_c

      # The guarantee: signal B sees the full slice signal A's cmd returned.
      assert domain.saw_cmd
      assert domain.saw_a
      assert domain.saw_b
      assert domain.saw_c
    end
  end
end
