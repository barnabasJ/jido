defmodule Jido.Agent.MultiInstanceFanOutTest do
  @moduledoc """
  Coverage for the multi-instance slice mount fan-out introduced by
  task 0062. The same slice/plugin module mounted at multiple paths
  (`slice :slack_support, SlackPlugin; slice :slack_sales, SlackPlugin`)
  no longer trips `NoRouteConflicts`; instead, when a signal targets the
  shared action, `cmd/2` fans the action out — once per matching mount
  with that mount's own slice state and `ctx.slice_config`.

  These tests cover:

    1. Compile-time acceptance of multi-instance same-plugin mounts.
    2. Per-mount state writes from a single `cmd/2` call.
    3. `ctx.slice_path` and `ctx.slice_config` visibility per fan-out
       iteration.
    4. Atomicity — first mount's success rolls back when a later mount
       errors (the cmd is all-or-nothing).
    5. Edge case: action declared in BOTH a slice's `signal_routes` AND
       the agent's own `signal_routes` fans out across slice mounts AND
       the agent path (design choice #1).
  """

  use ExUnit.Case, async: true

  # ─── Fixtures ──────────────────────────────────────────────────────

  defmodule SendAction do
    @moduledoc false
    use Jido.Action

    action do
      name "send"
      schema Zoi.object(%{message: Zoi.string()})
    end

    @impl true
    def run(%Jido.Signal{data: %{message: msg}}, slice, _opts, ctx) do
      slice = slice || %{}
      messages = Map.get(slice, :messages, [])
      token = get_in(ctx, [:slice_config, :token]) || "no-config"

      if pid = ctx[:test_pid] do
        send(pid, {:fan_out_call, ctx[:slice_path], token, msg})
      end

      if get_in(ctx, [:slice_config, :fail?]) do
        {:error, {:planned_failure, ctx[:slice_path]}}
      else
        {:ok, %{messages: messages ++ ["#{token}: #{msg}"]}, []}
      end
    end
  end

  defmodule SlackPlugin do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "slack_plugin"
      schema Zoi.object(%{messages: Zoi.array(Zoi.string()) |> Zoi.default([])})
    end

    signal_routes do
      route "slack.send", Jido.Agent.MultiInstanceFanOutTest.SendAction
    end
  end

  defmodule MultiSlackAgent do
    @moduledoc false
    use Jido.Agent, default_slices: false

    agent do
      name "multi_slack_agent"
    end

    slices do
      slice(:slack_support, SlackPlugin, options: %{token: "support-token"})
      slice(:slack_sales, SlackPlugin, options: %{token: "sales-token"})
    end
  end

  defmodule FailingMultiSlackAgent do
    @moduledoc false
    use Jido.Agent, default_slices: false

    agent do
      name "failing_multi_slack_agent"
    end

    slices do
      slice(:slack_support, SlackPlugin, options: %{token: "support-token"})

      slice(
        :slack_sales,
        SlackPlugin,
        options: %{token: "sales-token", fail?: true}
      )
    end
  end

  defmodule HostSlackAgent do
    @moduledoc false
    # Action declared in BOTH a slice's signal_routes AND the agent's own
    # signal_routes — exercises design choice #1: the agent path joins the
    # fan-out list.
    use Jido.Agent, default_slices: false

    agent do
      name "host_slack_agent"
      path :host
      schema Zoi.object(%{messages: Zoi.array(Zoi.string()) |> Zoi.default([])})
    end

    slices do
      slice(:slack_support, SlackPlugin, options: %{token: "support-token"})
      slice(:slack_sales, SlackPlugin, options: %{token: "sales-token"})
    end

    signal_routes do
      route "host.send", Jido.Agent.MultiInstanceFanOutTest.SendAction
    end
  end

  # ─── Tests ─────────────────────────────────────────────────────────

  describe "compile-time acceptance" do
    test "the same plugin module mounted at two different paths compiles cleanly" do
      # If this module compiled, the verifier accepted the multi-mount
      # configuration. Belt-and-braces: assert the agent's helpers exist.
      assert function_exported?(MultiSlackAgent, :cmd, 3)
      assert function_exported?(MultiSlackAgent, :new, 1)
    end

    test "slice_paths_for_action contains both mount paths for the shared action" do
      table = Jido.Dsl.Agent.Info.slice_paths_for_action(MultiSlackAgent)
      paths = Map.get(table, SendAction, [])

      assert :slack_support in paths
      assert :slack_sales in paths
      assert length(paths) == 2
    end

    test "mount_config_map exposes per-mount config" do
      configs = Jido.Dsl.Agent.Info.mount_config_map(MultiSlackAgent)

      assert configs[:slack_support][:token] == "support-token"
      assert configs[:slack_sales][:token] == "sales-token"
    end
  end

  describe "runtime fan-out" do
    test "one cmd updates both mount paths" do
      agent = MultiSlackAgent.new()
      assert agent.state.slack_support.messages == []
      assert agent.state.slack_sales.messages == []

      {:ok, signal} = Jido.Signal.new(%{type: "slack.send", data: %{message: "hi"}})

      {:ok, agent, _dirs} =
        MultiSlackAgent.cmd(agent, {SendAction, %{message: "hi"}}, input_signal: signal)

      assert agent.state.slack_support.messages == ["support-token: hi"]
      assert agent.state.slack_sales.messages == ["sales-token: hi"]
    end

    test "ctx.slice_path identifies the current mount per fan-out iteration" do
      agent = MultiSlackAgent.new()
      {:ok, signal} = Jido.Signal.new(%{type: "slack.send", data: %{message: "hi"}})

      {:ok, _agent, _dirs} =
        MultiSlackAgent.cmd(agent, {SendAction, %{message: "hi"}},
          ctx: %{test_pid: self()},
          input_signal: signal
        )

      assert_received {:fan_out_call, :slack_support, "support-token", "hi"}
      assert_received {:fan_out_call, :slack_sales, "sales-token", "hi"}
    end

    test "ctx.slice_config carries the right mount's resolved config" do
      agent = MultiSlackAgent.new()
      {:ok, signal} = Jido.Signal.new(%{type: "slack.send", data: %{message: "go"}})

      {:ok, agent, _dirs} =
        MultiSlackAgent.cmd(agent, {SendAction, %{message: "go"}}, input_signal: signal)

      # The action prepends the token to the message — proves each mount
      # saw its own slice_config token.
      assert agent.state.slack_support.messages == ["support-token: go"]
      assert agent.state.slack_sales.messages == ["sales-token: go"]
    end
  end

  describe "atomicity — first-mount success rolls back when a later mount errors" do
    test "the input agent's state is unchanged when any mount errors" do
      agent = FailingMultiSlackAgent.new()
      {:ok, signal} = Jido.Signal.new(%{type: "slack.send", data: %{message: "hi"}})

      assert {:error, _reason} =
               FailingMultiSlackAgent.cmd(agent, {SendAction, %{message: "hi"}},
                 input_signal: signal
               )

      # Re-fetch the agent state — it should match the initial state for
      # both mounts. The successful first mount's write to :slack_support
      # is dropped on the floor when the second mount errors.
      fresh = FailingMultiSlackAgent.new()
      assert agent.state.slack_support == fresh.state.slack_support
      assert agent.state.slack_sales == fresh.state.slack_sales
    end
  end

  describe "edge case: action shared by slice mounts AND agent's own signal_routes" do
    test "fan-out covers slice mounts AND the agent path" do
      agent = HostSlackAgent.new()
      {:ok, signal} = Jido.Signal.new(%{type: "host.send", data: %{message: "broadcast"}})

      {:ok, agent, _dirs} =
        HostSlackAgent.cmd(agent, {SendAction, %{message: "broadcast"}},
          ctx: %{test_pid: self()},
          input_signal: signal
        )

      # All three slices got an entry — slack_support and slack_sales
      # carry their tokens; :host (agent's own path, no slice_config) uses
      # the no-config marker.
      assert agent.state.slack_support.messages == ["support-token: broadcast"]
      assert agent.state.slack_sales.messages == ["sales-token: broadcast"]
      assert agent.state.host.messages == ["no-config: broadcast"]

      assert_received {:fan_out_call, :slack_support, "support-token", "broadcast"}
      assert_received {:fan_out_call, :slack_sales, "sales-token", "broadcast"}
      assert_received {:fan_out_call, :host, "no-config", "broadcast"}
    end
  end
end
