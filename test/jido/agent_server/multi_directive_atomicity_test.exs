defmodule JidoTest.AgentServer.MultiDirectiveAtomicityTest do
  @moduledoc """
  Signal A emits several synchronous directives [D1, D2, D3]. Signal B is
  cast right after. Under inline signal processing (ADR 0009), signal B's
  cmd/2 must observe state reflecting ALL of A's directives' synchronous
  updates — not a partial prefix.

  This was not guaranteed under the previous drain-loop architecture:
  signal B could be handled between D1 and D2, seeing a partial prefix.
  """
  use JidoTest.Case, async: true

  # ── Multi-directive atomicity (sync only) ────────────────────────────

  defmodule EmitThreeStateDirectivesAction do
    @moduledoc false
    use Jido.Action, name: "emit_three"

    def run(_signal, slice, _opts, _ctx) do
      directives = [
        %JidoTest.SetStateDirective{key: :d1_ran, value: true},
        %JidoTest.SetStateDirective{key: :d2_ran, value: true},
        %JidoTest.SetStateDirective{key: :d3_ran, value: true}
      ]

      {:ok, Map.put(slice || %{}, :cmd_ran, true), directives}
    end
  end

  defmodule ObserveAction do
    @moduledoc false
    use Jido.Action, name: "observe"

    def run(_signal, slice, _opts, _ctx) do
      slice = slice || %{}

      observation = %{
        saw_cmd: Map.get(slice, :cmd_ran, false),
        saw_d1: Map.get(slice, :d1_ran, false),
        saw_d2: Map.get(slice, :d2_ran, false),
        saw_d3: Map.get(slice, :d3_ran, false)
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
        d1_ran: [type: :boolean, default: false],
        d2_ran: [type: :boolean, default: false],
        d3_ran: [type: :boolean, default: false],
        saw_cmd: [type: :boolean, default: false],
        saw_d1: [type: :boolean, default: false],
        saw_d2: [type: :boolean, default: false],
        saw_d3: [type: :boolean, default: false]
      ]

    def signal_routes(_ctx) do
      [
        {"emit_three", EmitThreeStateDirectivesAction},
        {"observe", ObserveAction}
      ]
    end
  end

  describe "multi-directive atomicity" do
    test "signal B observes every synchronous directive from signal A", %{jido: jido} do
      pid = start_server(%{jido: jido}, AtomicityAgent)

      Jido.AgentServer.cast(pid, signal("emit_three", %{}))
      Jido.AgentServer.cast(pid, signal("observe", %{}))

      domain =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.saw_d3, do: s.agent.state.domain
        end)

      assert domain.cmd_ran
      assert domain.d1_ran
      assert domain.d2_ran
      assert domain.d3_ran

      # The guarantee: observe sees the full output of signal A.
      assert domain.saw_cmd
      assert domain.saw_d1
      assert domain.saw_d2
      assert domain.saw_d3
    end
  end
end
