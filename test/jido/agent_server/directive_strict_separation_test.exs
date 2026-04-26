defmodule JidoTest.AgentServer.DirectiveStrictSeparationTest do
  @moduledoc """
  Per ADR 0019 §1 / task 0015, directives mutate **no** state — neither
  `agent.state` (domain) nor `%AgentServer.State{}` (runtime). The
  `DirectiveExec.exec/3` contract enforces this in the type system
  (return is `:ok | {:stop, term()}` only).

  This module tests the runtime end of the rule for the Step-1
  violators (SpawnAgent, AdoptChild, Cron, CronCancel,
  RunInstruction):

  1. Apply the directive **inside the agent process** via a `state/3`
     selector, capturing pre/post state. Asserts byte-equality — the
     directive's `exec/3` does not mutate.
  2. Separately, assert that the natural cascade
     (`maybe_track_child_started`, `maybe_track_cron_*`, or the routed
     handler action for RunInstruction) eventually populates the
     relevant field via subscription-based `await_state_value/3`.

  StartNode/StopNode have their own test in
  `test/jido/pod/mutation_runtime_test.exs` (per task 0010).
  """
  use JidoTest.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.AgentServer
  alias Jido.AgentServer.DirectiveExec
  alias Jido.Signal

  defmodule EmitDirectiveAction do
    @moduledoc false
    use Jido.Action,
      name: "emit_directive",
      schema: [directive: [type: :any, required: true]]

    def run(%Jido.Signal{data: %{directive: directive}}, slice, _opts, _ctx) do
      {:ok, slice || %{}, [directive]}
    end
  end

  defmodule HarnessAgent do
    @moduledoc false
    use Jido.Agent,
      name: "directive_strict_harness",
      path: :domain,
      schema: [
        observed: [type: :any, default: nil]
      ]

    def signal_routes(_ctx) do
      [{"test.directive", EmitDirectiveAction}]
    end
  end

  defmodule SuccessAction do
    @moduledoc false
    use Jido.Action, name: "strict_success"
    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{ran: true}, []}
  end

  defmodule CaptureAction do
    @moduledoc false
    use Jido.Action,
      name: "strict_capture",
      schema: [
        status: [type: :atom, required: true],
        result: [type: :map, default: %{}],
        reason: [type: :any, default: nil],
        effects: [type: :any, default: []],
        instruction: [type: :any, default: nil],
        meta: [type: :map, default: %{}]
      ]

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      slice = slice || %{}
      {:ok, Map.put(slice, :captured, params.status), []}
    end
  end

  defmodule RoutedAgent do
    @moduledoc false
    use Jido.Agent,
      name: "strict_routed_agent",
      path: :domain,
      schema: [captured: [type: :atom, default: nil]]

    def signal_routes(_ctx) do
      [
        {"test.directive", JidoTest.AgentServer.DirectiveStrictSeparationTest.EmitDirectiveAction},
        {"test.routed.captured",
         JidoTest.AgentServer.DirectiveStrictSeparationTest.CaptureAction}
      ]
    end
  end

  defp signal_carrying_directive(directive) do
    Signal.new!(%{type: "test.directive", source: "/test", data: %{directive: directive}})
  end

  describe "SpawnAgent" do
    test "directive does not write state.children; cascade does", %{jido: jido} do
      pid = start_server(%{jido: jido}, HarnessAgent, id: "strict-spawn")

      directive = %Directive.SpawnAgent{
        agent: HarnessAgent,
        tag: :worker,
        opts: %{},
        meta: %{}
      }

      assert_no_runtime_mutation(pid, directive, fn s -> s.children end)

      child_info =
        await_state_value(
          pid,
          fn s -> Map.get(s.children, :worker) end,
          pattern: "jido.agent.child.started"
        )

      assert is_pid(child_info.pid)
      GenServer.stop(child_info.pid)
    end
  end

  describe "AdoptChild" do
    test "directive does not write state.children; cascade does", %{jido: jido} do
      parent_pid = start_server(%{jido: jido}, HarnessAgent, id: "strict-adopt-parent")
      orphan_pid = start_server(%{jido: jido}, HarnessAgent, id: "strict-adopt-orphan")

      directive = %Directive.AdoptChild{
        child: orphan_pid,
        tag: :adopted,
        meta: %{}
      }

      assert_no_runtime_mutation(parent_pid, directive, fn s -> s.children end)

      child_info =
        await_state_value(
          parent_pid,
          fn s -> Map.get(s.children, :adopted) end,
          pattern: "jido.agent.child.started"
        )

      assert child_info.pid == orphan_pid
      GenServer.stop(orphan_pid)
    end
  end

  describe "Cron" do
    test "directive does not write state.cron_*; cascade does", %{jido: jido} do
      pid = start_server(%{jido: jido}, HarnessAgent, id: "strict-cron")

      directive = %Directive.Cron{
        cron: "@hourly",
        message: :tick,
        job_id: :strict_cron,
        timezone: nil
      }

      assert_no_runtime_mutation(pid, directive, fn s ->
        %{
          specs: s.cron_specs,
          jobs: s.cron_jobs,
          monitors: s.cron_monitors,
          monitor_refs: s.cron_monitor_refs,
          runtime_specs: s.cron_runtime_specs
        }
      end)

      cron_pid =
        await_state_value(
          pid,
          fn s -> Map.get(s.cron_jobs, :strict_cron) end,
          pattern: "jido.agent.cron.registered"
        )

      assert is_pid(cron_pid)

      # The full cascade installs into all five maps in one shot.
      {:ok, all} =
        AgentServer.state(pid, fn s ->
          {:ok,
           %{
             specs: Map.has_key?(s.cron_specs, :strict_cron),
             jobs: Map.has_key?(s.cron_jobs, :strict_cron),
             monitors: Map.has_key?(s.cron_monitors, :strict_cron),
             runtime_specs: Map.has_key?(s.cron_runtime_specs, :strict_cron)
           }}
        end)

      assert all.specs
      assert all.jobs
      assert all.monitors
      assert all.runtime_specs

      AgentServer.cast(pid, signal_carrying_directive(%Directive.CronCancel{job_id: :strict_cron}))
    end
  end

  describe "CronCancel" do
    test "directive does not write state.cron_*; cascade does", %{jido: jido} do
      pid = start_server(%{jido: jido}, HarnessAgent, id: "strict-cron-cancel")

      AgentServer.cast(
        pid,
        signal_carrying_directive(%Directive.Cron{
          cron: "@hourly",
          message: :tick,
          job_id: :cancel_target,
          timezone: nil
        })
      )

      _cron_pid =
        await_state_value(
          pid,
          fn s -> Map.get(s.cron_jobs, :cancel_target) end,
          pattern: "jido.agent.cron.registered"
        )

      directive = %Directive.CronCancel{job_id: :cancel_target}

      # Capture state immediately after the directive runs (still inside
      # the agent process). The directive performs the I/O (cancel +
      # demonitor + persist) and casts a synthetic signal — the runtime
      # maps remain untouched within the same selector turn.
      {:ok, %{before: before_state, after: after_state}} =
        AgentServer.state(pid, fn s ->
          before_state = %{specs: s.cron_specs, jobs: s.cron_jobs, monitors: s.cron_monitors}
          input_signal = Signal.new!(%{type: "test.harness", source: "/test", data: %{}})
          :ok = DirectiveExec.exec(directive, input_signal, s)
          after_state = %{specs: s.cron_specs, jobs: s.cron_jobs, monitors: s.cron_monitors}
          {:ok, %{before: before_state, after: after_state}}
        end)

      assert before_state == after_state

      true =
        await_state_value(
          pid,
          fn s -> if not Map.has_key?(s.cron_jobs, :cancel_target), do: true end,
          pattern: "jido.agent.cron.cancelled"
        )

      {:ok, all} =
        AgentServer.state(pid, fn s ->
          {:ok,
           %{
             specs: Map.has_key?(s.cron_specs, :cancel_target),
             jobs: Map.has_key?(s.cron_jobs, :cancel_target),
             monitors: Map.has_key?(s.cron_monitors, :cancel_target),
             runtime_specs: Map.has_key?(s.cron_runtime_specs, :cancel_target)
           }}
        end)

      refute all.specs
      refute all.jobs
      refute all.monitors
      refute all.runtime_specs
    end
  end

  describe "RunInstruction" do
    test "directive does not write agent.state; the routed action does", %{jido: jido} do
      pid = start_server(%{jido: jido}, RoutedAgent, id: "strict-run-instr")

      instruction = Jido.Instruction.new!(%{action: SuccessAction})

      directive =
        Directive.run_instruction(instruction,
          result_signal_type: "test.routed.captured",
          meta: %{}
        )

      input_signal = Signal.new!(%{type: "test.harness", source: "/test", data: %{}})

      {:ok, %{before: before_domain, after: after_domain}} =
        AgentServer.state(pid, fn s ->
          before_domain = s.agent.state
          :ok = DirectiveExec.exec(directive, input_signal, s)
          {:ok, %{before: before_domain, after: s.agent.state}}
        end)

      # The directive's exec doesn't write agent.state — pre/post inside
      # the same selector turn must be byte-equal.
      assert before_domain == after_domain

      # The routed handler action commits the slice update on the next
      # mailbox turn.
      captured =
        await_state_value(
          pid,
          fn s -> s.agent.state.domain.captured end,
          pattern: "test.routed.captured"
        )

      assert captured == :ok
    end
  end

  # Captures state via a `state/3` selector both before and after
  # invoking `DirectiveExec.exec/3` synchronously inside the agent
  # process. Asserts the projection (`projector.(state)`) is byte-equal
  # — directives must not mutate runtime fields.
  defp assert_no_runtime_mutation(pid, directive, projector) do
    input_signal = Signal.new!(%{type: "test.harness", source: "/test", data: %{}})

    {:ok, %{before: before_value, after: after_value}} =
      AgentServer.state(pid, fn s ->
        before_value = projector.(s)
        :ok = DirectiveExec.exec(directive, input_signal, s)
        after_value = projector.(s)
        {:ok, %{before: before_value, after: after_value}}
      end)

    assert before_value == after_value
  end
end
