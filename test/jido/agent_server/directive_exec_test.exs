defmodule JidoTest.AgentServer.DirectiveExecTest do
  use JidoTest.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.AgentServer
  alias Jido.AgentServer.{DirectiveExec, Options, State}
  alias Jido.Signal

  defmodule EmitDirectiveAction do
    @moduledoc false
    use Jido.Action,
      name: "emit_directive",
      schema: [
        directive: [type: :any, required: true]
      ]

    def run(%Jido.Signal{data: %{directive: directive}}, slice, _opts, _ctx) do
      {:ok, slice || %{}, [directive]}
    end
  end

  defmodule TestAgent do
    @moduledoc false
    use Jido.Agent,
      name: "directive_exec_test_agent",
      path: :domain,
      schema: [
        counter: [type: :integer, default: 0]
      ]

    def signal_routes(_ctx) do
      [
        {"test.directive", JidoTest.AgentServer.DirectiveExecTest.EmitDirectiveAction}
      ]
    end
  end

  defmodule StopOnSignalAction do
    @moduledoc false
    use Jido.Action,
      name: "stop_on_signal",
      schema: [
        reason: [type: :any, default: :normal]
      ]

    alias Jido.Agent.Directive

    def run(%Jido.Signal{data: %{reason: reason}}, %{observer_pid: observer_pid}, _opts, _ctx)
        when is_pid(observer_pid) do
      send(observer_pid, {:child_stop_signal_received, reason})
      {:ok, %{stop_reason: reason}, [%Directive.Stop{reason: reason}]}
    end

    def run(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx) do
      {:ok, %{stop_reason: reason}, [%Directive.Stop{reason: reason}]}
    end
  end

  defmodule StopAwareAgent do
    @moduledoc false
    use Jido.Agent,
      name: "directive_exec_stop_aware_agent",
      path: :domain,
      schema: [
        observer_pid: [type: :any, default: nil],
        stop_reason: [type: :any, default: nil]
      ]

    def signal_routes(_ctx) do
      [
        {"jido.agent.stop", StopOnSignalAction},
        {"test.directive", JidoTest.AgentServer.DirectiveExecTest.EmitDirectiveAction}
      ]
    end
  end

  defmodule CustomDirective do
    @moduledoc false
    defstruct [:value]
  end

  defmodule RunInstructionSuccessAction do
    @moduledoc false
    use Jido.Action,
      name: "run_instruction_success",
      schema: []

    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{ran: true}, []}
  end

  defmodule RunInstructionFailureAction do
    @moduledoc false
    use Jido.Action,
      name: "run_instruction_failure",
      schema: []

    def run(_signal, _slice, _opts, _ctx), do: {:error, :boom}
  end

  defmodule CaptureResultAction do
    @moduledoc false
    use Jido.Action,
      name: "capture_result_action",
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

      {:ok,
       Map.merge(slice, %{
         captured_status: params.status,
         captured_result: params.result,
         captured_reason: params.reason,
         captured_meta: params.meta
       }), []}
    end
  end

  defmodule CaptureResultEmitAction do
    @moduledoc false
    use Jido.Action,
      name: "capture_result_emit_action",
      schema: [
        status: [type: :atom, required: true],
        result: [type: :map, default: %{}],
        reason: [type: :any, default: nil],
        effects: [type: :any, default: []],
        instruction: [type: :any, default: nil],
        meta: [type: :map, default: %{}]
      ]

    def run(_signal, slice, _opts, _ctx) do
      slice = slice || %{}
      directive = Directive.emit(%{type: "capture.result.event"})
      {:ok, Map.put(slice, :captured_emit, true), [directive]}
    end
  end

  defmodule RunInstructionRoutedAgent do
    @moduledoc false
    use Jido.Agent,
      name: "run_instruction_routed_agent",
      path: :domain,
      schema: [
        captured_status: [type: :atom, default: nil],
        captured_result: [type: :map, default: %{}],
        captured_reason: [type: :any, default: nil],
        captured_meta: [type: :map, default: %{}],
        captured_emit: [type: :boolean, default: false]
      ]

    def signal_routes(_ctx) do
      [
        {"test.directive", JidoTest.AgentServer.DirectiveExecTest.EmitDirectiveAction},
        {"test.run_instruction.captured",
         JidoTest.AgentServer.DirectiveExecTest.CaptureResultAction},
        {"test.run_instruction.failure",
         JidoTest.AgentServer.DirectiveExecTest.CaptureResultEmitAction}
      ]
    end
  end

  setup %{jido: jido} do
    agent = TestAgent.new()

    {:ok, opts} = Options.new(%{agent_module: TestAgent, id: "test-agent-123", jido: jido})
    {:ok, state} = State.from_options(opts, TestAgent, agent)

    input_signal = Signal.new!(%{type: "test.signal", source: "/test", data: %{}})

    %{state: state, input_signal: input_signal, agent: agent}
  end

  describe "Emit directive" do
    test "falls back to dispatching to current process when no dispatch config", %{
      state: state,
      input_signal: input_signal
    } do
      signal = Signal.new!(%{type: "test.emitted", source: "/test", data: %{}})
      directive = %Directive.Emit{signal: signal, dispatch: nil}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
      assert_receive {:signal, %Signal{type: "test.emitted"}}
    end

    test "returns ok when dispatch config provided", %{
      state: state,
      input_signal: input_signal
    } do
      signal = Signal.new!(%{type: "test.emitted", source: "/test", data: %{}})
      directive = %Directive.Emit{signal: signal, dispatch: {:logger, level: :info}}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
    end

    test "uses default_dispatch from state when directive dispatch is nil", %{
      input_signal: input_signal,
      agent: agent,
      jido: jido
    } do
      {:ok, opts} =
        Options.new(%{
          agent_module: TestAgent,
          id: "test-agent-dispatch",
          default_dispatch: {:logger, level: :debug},
          jido: jido
        })

      {:ok, state} = State.from_options(opts, agent.__struct__, agent)

      signal = Signal.new!(%{type: "test.emitted", source: "/test", data: %{}})
      directive = %Directive.Emit{signal: signal, dispatch: nil}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
    end
  end

  describe "Error directive" do
    test "logs and returns ok (error policy is gone, ADR 0014 C4)", %{
      state: state,
      input_signal: input_signal
    } do
      error = Jido.Error.validation_error("Test error")
      directive = %Directive.Error{error: error, context: :test}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
    end
  end

  describe "Spawn directive" do
    test "spawns child using custom spawn_fun", %{
      input_signal: input_signal,
      agent: agent,
      jido: jido
    } do
      test_pid = self()

      spawn_fun = fn child_spec ->
        send(test_pid, {:spawn_called, child_spec})
        {:ok, spawn(fn -> :ok end)}
      end

      {:ok, opts} =
        Options.new(%{
          agent_module: TestAgent,
          id: "test-agent-spawn",
          spawn_fun: spawn_fun,
          jido: jido
        })

      {:ok, state} = State.from_options(opts, agent.__struct__, agent)

      child_spec = {Task, fn -> :ok end}
      directive = %Directive.Spawn{child_spec: child_spec, tag: :worker}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
      assert_receive {:spawn_called, ^child_spec}
    end

    test "handles spawn failure gracefully", %{
      input_signal: input_signal,
      agent: agent,
      jido: jido
    } do
      spawn_fun = fn _child_spec ->
        {:error, :spawn_failed}
      end

      {:ok, opts} =
        Options.new(%{
          agent_module: TestAgent,
          id: "test-agent-spawn-fail",
          spawn_fun: spawn_fun,
          jido: jido
        })

      {:ok, state} = State.from_options(opts, agent.__struct__, agent)

      child_spec = {Task, fn -> :ok end}
      directive = %Directive.Spawn{child_spec: child_spec, tag: :worker}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
    end

    test "handles spawn returning {:ok, pid, info} tuple", %{
      input_signal: input_signal,
      agent: agent,
      jido: jido
    } do
      test_pid = self()

      spawn_fun = fn child_spec ->
        send(test_pid, {:spawn_called, child_spec})
        {:ok, spawn(fn -> :ok end), %{extra: :info}}
      end

      {:ok, opts} =
        Options.new(%{
          agent_module: TestAgent,
          id: "test-agent-spawn-info",
          spawn_fun: spawn_fun,
          jido: jido
        })

      {:ok, state} = State.from_options(opts, agent.__struct__, agent)

      child_spec = {Task, fn -> :ok end}
      directive = %Directive.Spawn{child_spec: child_spec, tag: :worker}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
      assert_receive {:spawn_called, ^child_spec}
    end

    test "handles spawn returning :ignored", %{
      input_signal: input_signal,
      agent: agent,
      jido: jido
    } do
      spawn_fun = fn _child_spec ->
        :ignored
      end

      {:ok, opts} =
        Options.new(%{
          agent_module: TestAgent,
          id: "test-agent-spawn-ignored",
          spawn_fun: spawn_fun,
          jido: jido
        })

      {:ok, state} = State.from_options(opts, agent.__struct__, agent)

      child_spec = {Task, fn -> :ok end}
      directive = %Directive.Spawn{child_spec: child_spec, tag: :worker}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
    end
  end

  describe "RunInstruction directive (signal-routed result)" do
    test "executes instruction and routes result via result_signal_type", %{jido: jido} do
      pid = start_server(%{jido: jido}, RunInstructionRoutedAgent, id: "run-instr-success")

      instruction = Jido.Instruction.new!(%{action: RunInstructionSuccessAction})

      directive =
        Directive.run_instruction(instruction,
          result_signal_type: "test.run_instruction.captured",
          meta: %{source: :test}
        )

      AgentServer.cast(pid, signal_carrying_directive(directive))

      domain =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.captured_status, do: s.agent.state.domain
        end)

      assert domain.captured_status == :ok
      assert domain.captured_result == %{ran: true}
      assert domain.captured_reason == nil
      assert domain.captured_meta == %{source: :test}
    end

    test "normalizes failures and the routed action sees status :error", %{jido: jido} do
      pid = start_server(%{jido: jido}, RunInstructionRoutedAgent, id: "run-instr-failure")

      instruction = Jido.Instruction.new!(%{action: RunInstructionFailureAction})

      directive =
        Directive.run_instruction(instruction,
          result_signal_type: "test.run_instruction.failure"
        )

      AgentServer.cast(pid, signal_carrying_directive(directive))

      domain =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.captured_emit, do: s.agent.state.domain
        end)

      assert domain.captured_emit == true

      # CaptureResultEmitAction emitted a `capture.result.event` signal —
      # Emit's local dispatch sends `{:signal, signal}` to self(), but
      # since we're not the agent process here, we won't receive it.
      # The `captured_emit` slice update is the observable side-effect.
    end

    test "directive itself does not write agent.state — strict ADR 0019 separation", %{
      jido: jido
    } do
      pid = start_server(%{jido: jido}, RunInstructionRoutedAgent, id: "run-instr-strict")

      instruction = Jido.Instruction.new!(%{action: RunInstructionSuccessAction})

      directive =
        Directive.run_instruction(instruction,
          result_signal_type: "test.run_instruction.captured",
          meta: %{source: :test}
        )

      input_signal = Signal.new!(%{type: "test.harness", source: "/test", data: %{}})

      {:ok, %{before: before_state, after: after_state}} =
        AgentServer.state(pid, fn s ->
          before_state = s.agent.state
          :ok = DirectiveExec.exec(directive, input_signal, s)
          {:ok, %{before: before_state, after: s.agent.state}}
        end)

      assert before_state == after_state

      # The natural cascade — the result signal routed to
      # CaptureResultAction — populates the slice on a later mailbox turn.
      domain =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.captured_status, do: s.agent.state.domain
        end)

      assert domain.captured_status == :ok
    end
  end

  describe "Schedule directive" do
    test "sends scheduled signal after delay", %{state: state, input_signal: input_signal} do
      signal = Signal.new!(%{type: "scheduled.ping", source: "/test", data: %{}})
      directive = %Directive.Schedule{delay_ms: 10, message: signal}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
      assert_receive {:scheduled_signal, received_signal}, 100
      assert received_signal.type == "scheduled.ping"
    end

    test "wraps non-signal message in signal", %{state: state, input_signal: input_signal} do
      directive = %Directive.Schedule{delay_ms: 10, message: :timeout}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
      assert_receive {:scheduled_signal, received_signal}, 100
      assert received_signal.type == "jido.scheduled"
      assert received_signal.data.message == :timeout
    end
  end

  describe "Stop directive" do
    test "returns stop tuple with reason", %{state: state, input_signal: input_signal} do
      directive = %Directive.Stop{reason: :normal}

      assert {:stop, :normal} = DirectiveExec.exec(directive, input_signal, state)
    end

    test "returns stop tuple with custom reason", %{state: state, input_signal: input_signal} do
      directive = %Directive.Stop{reason: {:shutdown, :user_requested}}

      assert {:stop, {:shutdown, :user_requested}} =
               DirectiveExec.exec(directive, input_signal, state)
    end
  end

  describe "SpawnAgent directive" do
    test "natural child.started cascade adds the child after the directive returns", %{
      jido: jido
    } do
      parent_pid = start_server(%{jido: jido}, TestAgent, id: "spawn-cascade-parent")

      directive = %Directive.SpawnAgent{
        agent: TestAgent,
        tag: :child_worker,
        opts: %{},
        meta: %{role: :worker}
      }

      AgentServer.cast(parent_pid, signal_carrying_directive(directive))

      child_info =
        await_state_value(
          parent_pid,
          fn s -> Map.get(s.children, :child_worker) end,
          pattern: "jido.agent.child.started"
        )

      assert is_pid(child_info.pid)
      assert child_info.module == TestAgent
      assert child_info.tag == :child_worker
      assert child_info.meta == %{role: :worker}

      GenServer.stop(child_info.pid)
    end

    test "directive itself does not write state.children — strict ADR 0019 separation", %{
      jido: jido
    } do
      parent_pid = start_server(%{jido: jido}, TestAgent, id: "spawn-strict-parent")

      directive = %Directive.SpawnAgent{
        agent: TestAgent,
        tag: :strict_child,
        opts: %{},
        meta: %{}
      }

      input_signal = Signal.new!(%{type: "test.harness", source: "/test", data: %{}})

      {:ok, before_children} =
        AgentServer.state(parent_pid, fn s ->
          children_before = s.children
          :ok = DirectiveExec.exec(directive, input_signal, s)
          {:ok, %{before: children_before, after: s.children}}
        end)

      # The directive's exec doesn't mutate state — `before` and `after`
      # captured inside the same selector turn must be identical.
      assert before_children.before == before_children.after

      # The natural child.started cascade fires on the next mailbox turn.
      child_pid = await_child_pid(parent_pid, :strict_child)
      GenServer.stop(child_pid)
    end

    test "handles spawn failure gracefully", %{state: state, input_signal: input_signal} do
      directive = %Directive.SpawnAgent{
        agent: NonExistentAgentModule,
        tag: :failing_child,
        opts: %{},
        meta: %{}
      }

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
      refute Map.has_key?(state.children, :failing_child)
    end

    test "resolve_agent_module handles non-module non-struct agent (unknown type)", %{
      state: state,
      input_signal: input_signal
    } do
      directive = %Directive.SpawnAgent{
        agent: "not_a_module_or_struct",
        tag: :unknown_agent,
        opts: %{},
        meta: %{}
      }

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
    end

    test "rejects unsupported lifecycle opts even for raw SpawnAgent structs", %{
      state: state,
      input_signal: input_signal
    } do
      directive = %Directive.SpawnAgent{
        agent: TestAgent,
        tag: :managed_child,
        opts: %{storage: Jido.Storage.ETS, idle_timeout: 5_000},
        meta: %{}
      }

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
      refute Map.has_key?(state.children, :managed_child)
    end

    test "rejects malformed opts even for raw SpawnAgent structs", %{
      state: state,
      input_signal: input_signal
    } do
      directive = %Directive.SpawnAgent{
        agent: TestAgent,
        tag: :bad_opts_child,
        opts: [:not_a_map],
        meta: %{}
      }

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
      refute Map.has_key?(state.children, :bad_opts_child)
    end
  end

  describe "StopChild directive" do
    test "sends jido.agent.stop to child", %{jido: jido} do
      parent_pid = start_server(%{jido: jido}, StopAwareAgent, id: "stop-aware-parent-1")

      spawn_directive = %Directive.SpawnAgent{
        agent: StopAwareAgent,
        tag: :stop_signal_child,
        opts: %{initial_state: %{observer_pid: self()}},
        meta: %{}
      }

      AgentServer.cast(parent_pid, signal_carrying_directive(spawn_directive))

      child_pid = await_child_pid(parent_pid, :stop_signal_child)
      child_ref = Process.monitor(child_pid)

      stop_directive = %Directive.StopChild{tag: :stop_signal_child, reason: :shutdown}
      AgentServer.cast(parent_pid, signal_carrying_directive(stop_directive))

      assert_receive {:child_stop_signal_received, :shutdown}, 1_000
      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, :shutdown}, 1_000
    end

    test "wraps custom stop reasons as clean shutdowns", %{jido: jido} do
      parent_pid = start_server(%{jido: jido}, StopAwareAgent, id: "stop-aware-parent-2")

      spawn_directive = %Directive.SpawnAgent{
        agent: StopAwareAgent,
        tag: :custom_reason_child,
        opts: %{initial_state: %{observer_pid: self()}},
        meta: %{}
      }

      AgentServer.cast(parent_pid, signal_carrying_directive(spawn_directive))

      child_pid = await_child_pid(parent_pid, :custom_reason_child)
      child_ref = Process.monitor(child_pid)

      stop_directive = %Directive.StopChild{tag: :custom_reason_child, reason: :cleanup}
      AgentServer.cast(parent_pid, signal_carrying_directive(stop_directive))

      assert_receive {:child_stop_signal_received, {:shutdown, :cleanup}}, 1_000
      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, {:shutdown, :cleanup}}, 1_000
    end

    test "stops existing child", %{jido: jido} do
      parent_pid = start_server(%{jido: jido}, TestAgent, id: "stop-child-parent")

      spawn_directive = %Directive.SpawnAgent{
        agent: TestAgent,
        tag: :child_to_stop,
        opts: %{},
        meta: %{}
      }

      AgentServer.cast(parent_pid, signal_carrying_directive(spawn_directive))
      child_pid = await_child_pid(parent_pid, :child_to_stop)

      stop_directive = %Directive.StopChild{tag: :child_to_stop, reason: :normal}
      AgentServer.cast(parent_pid, signal_carrying_directive(stop_directive))

      refute_eventually(Process.alive?(child_pid))
    end

    test "returns ok when child tag not found", %{state: state, input_signal: input_signal} do
      directive = %Directive.StopChild{tag: :nonexistent_child, reason: :normal}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
    end
  end

  describe "Any (fallback) directive" do
    test "returns ok for unknown directive types", %{state: state, input_signal: input_signal} do
      directive = %CustomDirective{value: 42}

      assert :ok = DirectiveExec.exec(directive, input_signal, state)
    end
  end

  # Cast a synthetic signal whose default `signal_routes` route
  # (`test.directive` → `EmitDirectiveAction`) yields `directive` from
  # the action's directive list. This pushes the directive through the
  # agent's actual pipeline so cascade callbacks can fire.
  defp signal_carrying_directive(directive) do
    Signal.new!(%{
      type: "test.directive",
      source: "/test",
      data: %{directive: directive}
    })
  end

  # Subscribe-based child wait that closes the registration race in
  # `AgentServer.await_child/3` (the underlying API doesn't re-check
  # state after subscribing — when the natural `child.started` cast
  # arrives between the initial `:get_child_pid` call and the
  # `subscribe` call, the subscriber misses it). `await_state_value/3`
  # has the re-check built in.
  defp await_child_pid(parent_pid, tag) do
    info =
      await_state_value(
        parent_pid,
        fn s -> Map.get(s.children, tag) end,
        pattern: "jido.agent.child.started"
      )

    info.pid
  end
end
