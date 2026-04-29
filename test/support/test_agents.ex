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

    def signal_routes(_ctx), do: []
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

    def signal_routes(_ctx) do
      [
        {"increment", JidoTest.TestActions.IncrementAction},
        {"decrement", JidoTest.TestActions.DecrementAction},
        {"record", JidoTest.TestActions.RecordAction},
        {"slow", JidoTest.TestActions.SlowAction},
        {"fail", JidoTest.TestActions.FailingAction}
      ]
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

    def signal_routes(_ctx), do: []
  end

  defmodule Hook do
    @moduledoc false
    use Jido.Agent

    agent do
      name "hook_agent"
      path :domain
      schema counter: [type: :integer, default: 0]
    end

    def signal_routes(_ctx), do: []

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

    def signal_routes(_ctx), do: []
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
      extensions: [JidoTest.TestAgents.TestPluginWithRoutes],
      default_slices: false

    agent do
      name "agent_with_plugin_routes"
    end

    def signal_routes(_ctx), do: []
  end

  defmodule AgentWithMultiInstancePlugins do
    @moduledoc false
    use Jido.Agent,
      extensions: [
        {JidoTest.TestAgents.TestPluginWithRoutes, [as: :support]},
        {JidoTest.TestAgents.TestPluginWithRoutes, [as: :sales]}
      ],
      default_slices: false

    agent do
      name "agent_multi_instance"
    end

    def signal_routes(_ctx), do: []
  end
end
