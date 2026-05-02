defmodule JidoTest.Agent.DirectiveTest do
  use ExUnit.Case, async: true

  alias Jido.Directives

  describe "emit/2" do
    test "creates Emit directive without dispatch" do
      signal = %{type: "test"}
      directive = Directives.emit(signal)
      assert %Directives.Emit{signal: ^signal, dispatch: nil} = directive
    end

    test "creates Emit directive with dispatch config" do
      signal = %{type: "test"}
      directive = Directives.emit(signal, {:pubsub, topic: "events"})
      assert directive.signal == signal
      assert directive.dispatch == {:pubsub, topic: "events"}
    end
  end

  describe "error/2" do
    test "creates Error directive without context" do
      error = %{message: "test error"}
      directive = Directives.error(error)
      assert %Directives.Error{error: ^error, context: nil} = directive
    end

    test "creates Error directive with context" do
      error = %{message: "test error"}
      directive = Directives.error(error, :normalize)
      assert directive.error == error
      assert directive.context == :normalize
    end
  end

  describe "spawn/2" do
    test "creates Spawn directive without tag" do
      child_spec = {MyWorker, arg: :value}
      directive = Directives.spawn(child_spec)
      assert %Directives.Spawn{child_spec: ^child_spec, tag: nil} = directive
    end

    test "creates Spawn directive with tag" do
      child_spec = {MyWorker, arg: :value}
      directive = Directives.spawn(child_spec, :worker_1)
      assert directive.child_spec == child_spec
      assert directive.tag == :worker_1
    end
  end

  describe "spawn_agent/3" do
    test "creates SpawnAgent directive with defaults" do
      directive = Directives.spawn_agent(MyAgent, :worker_1)
      assert %Directives.SpawnAgent{} = directive
      assert directive.agent == MyAgent
      assert directive.tag == :worker_1
      assert directive.opts == %{}
      assert directive.meta == %{}
      assert directive.restart == :transient
    end

    test "creates SpawnAgent directive with opts" do
      directive =
        Directives.spawn_agent(MyAgent, :processor, opts: %{initial_state: %{batch: 100}})

      assert directive.opts == %{initial_state: %{batch: 100}}
      assert directive.meta == %{}
      assert directive.restart == :transient
    end

    test "creates SpawnAgent directive with meta" do
      directive = Directives.spawn_agent(MyAgent, :handler, meta: %{topic: "events"})
      assert directive.opts == %{}
      assert directive.meta == %{topic: "events"}
      assert directive.restart == :transient
    end

    test "creates SpawnAgent directive with both opts and meta" do
      directive =
        Directives.spawn_agent(MyAgent, :worker,
          opts: %{id: "custom"},
          meta: %{assigned: true}
        )

      assert directive.opts == %{id: "custom"}
      assert directive.meta == %{assigned: true}
      assert directive.restart == :transient
    end

    test "creates SpawnAgent directive with explicit restart policy" do
      directive = Directives.spawn_agent(MyAgent, :durable, restart: :permanent)

      assert directive.restart == :permanent
    end

    test "raises validation error for unsupported lifecycle opts" do
      assert_raise Jido.Error.ValidationError,
                   ~r/SpawnAgent does not support lifecycle\/persistence opts/,
                   fn ->
                     Directives.spawn_agent(MyAgent, :worker,
                       opts: %{storage: Jido.Storage.ETS, idle_timeout: 5_000}
                     )
                   end
    end

    test "raises validation error when opts is not a map" do
      assert_raise Jido.Error.ValidationError, ~r/SpawnAgent opts must be a map/, fn ->
        Directives.spawn_agent(MyAgent, :worker, opts: [:not_a_map])
      end
    end
  end

  describe "adopt_child/3" do
    test "creates AdoptChild directive for pid" do
      directive = Directives.adopt_child(self(), :worker_1)
      assert %Directives.AdoptChild{child: child, tag: :worker_1, meta: %{}} = directive
      assert child == self()
    end

    test "creates AdoptChild directive for child id with meta" do
      directive = Directives.adopt_child("child-123", :worker_1, meta: %{restored: true})

      assert directive.child == "child-123"
      assert directive.tag == :worker_1
      assert directive.meta == %{restored: true}
    end

    test "raises validation error for unsupported child reference" do
      assert_raise Jido.Error.ValidationError, fn ->
        Directives.adopt_child(:not_a_pid_or_id, :worker_1)
      end
    end
  end

  describe "stop_child/2" do
    test "creates StopChild directive with default reason" do
      directive = Directives.stop_child(:worker_1)
      assert %Directives.StopChild{tag: :worker_1, reason: :normal} = directive
    end

    test "creates StopChild directive with custom reason" do
      directive = Directives.stop_child(:processor, :shutdown)
      assert directive.tag == :processor
      assert directive.reason == :shutdown
    end
  end

  describe "schedule/2" do
    test "creates Schedule directive" do
      directive = Directives.schedule(5000, :timeout)
      assert %Directives.Schedule{delay_ms: 5000, message: :timeout} = directive
    end

    test "creates Schedule directive with complex message" do
      directive = Directives.schedule(1000, {:check, ref: "abc123"})
      assert directive.delay_ms == 1000
      assert directive.message == {:check, ref: "abc123"}
    end
  end

  describe "stop/1" do
    test "creates Stop directive with default reason" do
      directive = Directives.stop()
      assert %Directives.Stop{reason: :normal} = directive
    end

    test "creates Stop directive with custom reason" do
      directive = Directives.stop(:shutdown)
      assert directive.reason == :shutdown
    end
  end

  describe "emit_to_pid/3" do
    test "creates Emit directive targeting a pid" do
      signal = %{type: "test"}
      pid = self()
      directive = Directives.emit_to_pid(signal, pid)
      assert %Directives.Emit{signal: ^signal, dispatch: {:pid, opts}} = directive
      assert opts[:target] == pid
    end

    test "merges extra options" do
      signal = %{type: "test"}
      pid = self()
      directive = Directives.emit_to_pid(signal, pid, delivery_mode: :sync, timeout: 10_000)
      {:pid, opts} = directive.dispatch
      assert opts[:target] == pid
      assert opts[:delivery_mode] == :sync
      assert opts[:timeout] == 10_000
    end
  end

  describe "cron/3" do
    test "creates Cron directive with defaults" do
      directive = Directives.cron("* * * * *", :tick)
      assert %Directives.Cron{} = directive
      assert directive.cron == "* * * * *"
      assert directive.message == :tick
      assert directive.job_id == nil
      assert directive.timezone == nil
    end

    test "creates Cron directive with job_id" do
      directive = Directives.cron("@daily", :cleanup, job_id: :daily_cleanup)
      assert directive.cron == "@daily"
      assert directive.message == :cleanup
      assert directive.job_id == :daily_cleanup
    end

    test "creates Cron directive with timezone" do
      directive = Directives.cron("0 9 * * MON", :weekly, timezone: "America/New_York")
      assert directive.timezone == "America/New_York"
    end

    test "creates Cron directive with all options" do
      directive = Directives.cron("*/5 * * * *", :check, job_id: :health, timezone: "UTC")
      assert directive.job_id == :health
      assert directive.timezone == "UTC"
    end
  end

  describe "cron_cancel/1" do
    test "creates CronCancel directive" do
      directive = Directives.cron_cancel(:heartbeat)
      assert %Directives.CronCancel{} = directive
      assert directive.job_id == :heartbeat
    end
  end

  describe "schema functions" do
    @schema_modules [
      Directives.Emit,
      Directives.Error,
      Directives.Spawn,
      Directives.SpawnAgent,
      Directives.AdoptChild,
      Directives.StopChild,
      Directives.Schedule,
      Directives.Stop,
      Directives.Cron,
      Directives.CronCancel
    ]

    for module <- @schema_modules do
      @module module
      test "#{inspect(@module)}.schema/0 returns Zoi schema" do
        schema = @module.schema()
        assert is_struct(schema)
      end
    end
  end
end
