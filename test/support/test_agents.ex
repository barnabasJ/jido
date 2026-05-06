defmodule JidoTest.TestAgents do
  @moduledoc """
  Shared test agents for Jido test suite.
  """

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

  defmodule TestSliceWithRoutes do
    @moduledoc false
    use Jido.Slice

    slice do
      name "test_routes_slice"
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "post", JidoTest.PluginTestAction
      route "list", JidoTest.PluginTestAction
    end
  end

  defmodule TestSliceWithPriority do
    @moduledoc false
    use Jido.Slice

    slice do
      name "priority_slice"
      schema Zoi.object(%{value: Zoi.any() |> Zoi.optional()})
    end

    signal_routes do
      route "action", JidoTest.PluginTestAction, priority: 5
    end
  end

  defmodule AgentWithSliceRoutes do
    @moduledoc false
    use Jido.Agent, default_slices: false

    agent do
      name "agent_with_slice_routes"
    end

    slices do
      slice(:test_routes, JidoTest.TestAgents.TestSliceWithRoutes)
    end
  end
end
