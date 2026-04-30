defmodule JidoTest.TestAgents do
  @moduledoc """
  Shared test agents for Jido test suite.
  """

  # Ensure test actions are compiled before this module
  # (required for compile-time validation in use Jido.Plugin)
  Code.ensure_compiled!(JidoTest.PluginTestAction)
  Code.ensure_compiled!(JidoTest.TestActions.IncrementAction)

  defmodule Minimal do
    @moduledoc false
    use Jido.Agent

    agent do
      name "minimal_agent"
    end
  end

  defmodule Counter do
    @moduledoc """
    Standard test agent with counter and messages state.

    Routes:
      - "increment" -> IncrementAction
      - "decrement" -> DecrementAction
      - "record" -> RecordAction
      - "slow" -> SlowAction
      - "fail" -> FailingAction
    """
    use Jido.Agent

    agent do
      name "counter_agent"
      description "Test agent with counter and message tracking"
      path :domain

      schema counter: [type: :integer, default: 0],
             messages: [type: {:list, :any}, default: []]
    end

    signal_routes do
      route "increment", JidoTest.TestActions.IncrementAction
      route "decrement", JidoTest.TestActions.DecrementAction
      route "record", JidoTest.TestActions.RecordAction
      route "slow", JidoTest.TestActions.SlowAction
      route "fail", JidoTest.TestActions.FailingAction
    end
  end

  defmodule Basic do
    @moduledoc false
    use Jido.Agent

    agent do
      name "basic_agent"
      description "A basic test agent"
      category "test"
      tags ["test", "basic"]
      vsn "1.0.0"
      path :domain

      schema counter: [type: :integer, default: 0],
             status: [type: :atom, default: :idle]
    end
  end

  defmodule Hook do
    @moduledoc false
    use Jido.Agent

    agent do
      name "hook_agent"
      path :domain
      schema counter: [type: :integer, default: 0]
    end

    def on_after_cmd(agent, _action, directives) do
      new_agent = %{agent | state: put_in(agent.state, [:domain, :hook_called], true)}
      {:ok, new_agent, directives}
    end
  end

  defmodule ZoiSchema do
    @moduledoc false
    use Jido.Agent

    agent do
      name "zoi_schema_agent"
      path :domain

      schema(
        Zoi.object(%{
          status: Zoi.atom() |> Zoi.default(:idle),
          count: Zoi.integer() |> Zoi.default(0)
        })
      )
    end
  end

  defmodule TestPluginWithRoutes do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "test_routes_plugin"
      path :test_routes
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "post", JidoTest.PluginTestAction
      route "list", JidoTest.PluginTestAction
    end
  end

  defmodule TestPluginWithPriority do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "priority_plugin"
      path :priority
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "action", JidoTest.PluginTestAction, priority: 5
    end
  end

  defmodule AgentWithPluginRoutes do
    @moduledoc false
    use Jido.Agent,
      middleware: [JidoTest.TestAgents.TestPluginWithRoutes],
      default_slices: false

    agent do
      name "agent_with_plugin_routes"
    end

    slices do
      slice(:test_routes, JidoTest.TestAgents.TestPluginWithRoutes)
    end
  end

  # TODO: revisit per task 0053 — `as:` override semantics (re-mount the same
  # plugin under multiple paths) no longer apply to the unambiguous `slices do …`
  # block. The original test exercised two-instance mounting via `{Plugin, as: :foo}`
  # tuples; the new shape would require per-mount route prefixing, which task 0053
  # explicitly defers. Mount once for now so the file compiles; reinstate
  # per-instance routing in a follow-up if the test premise is still relevant.
  defmodule AgentWithMultiInstancePlugins do
    @moduledoc false
    use Jido.Agent,
      middleware: [JidoTest.TestAgents.TestPluginWithRoutes],
      default_slices: false

    agent do
      name "agent_multi_instance"
    end

    slices do
      slice(:support, JidoTest.TestAgents.TestPluginWithRoutes)
    end
  end
end
