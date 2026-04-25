defmodule JidoTest.AgentServer.MiddlewarePipelineTest do
  use JidoTest.Case, async: false

  alias Jido.AgentServer

  defmodule TaggingMiddleware do
    @moduledoc false
    use Jido.Middleware

    @impl true
    def on_signal(signal, ctx, opts, next) do
      tag = opts[:tag] || :default
      ctx = Map.update(ctx, :tags, [tag], &(&1 ++ [tag]))
      next.(signal, ctx)
    end
  end

  defmodule InspectAction do
    @moduledoc false
    use Jido.Action, name: "inspect", path: :app, schema: []

    def run(_signal, slice, _opts, ctx) do
      {:ok, %{slice | last_tags: ctx[:tags] || []}, []}
    end
  end

  defmodule MiddlewareAgent do
    @moduledoc false
    use Jido.Agent,
      name: "middleware_pipeline_agent",
      path: :app,
      schema: [
        last_tags: [type: {:list, :any}, default: []]
      ],
      middleware: [
        {JidoTest.AgentServer.MiddlewarePipelineTest.TaggingMiddleware, %{tag: :outer}},
        {JidoTest.AgentServer.MiddlewarePipelineTest.TaggingMiddleware, %{tag: :inner}}
      ]

    def signal_routes(_ctx), do: [{"inspect", JidoTest.AgentServer.MiddlewarePipelineTest.InspectAction}]
  end

  defp inspect_sig do
    {:ok, sig} = Jido.Signal.new(%{type: "inspect", source: "/test", data: %{}})
    sig
  end

  describe "compile-time middleware chain" do
    test "outside-in composition order: outer middleware sees signal first", %{jido: jido} do
      pid = start_server(%{jido: jido}, MiddlewareAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, agent} = AgentServer.call(pid, inspect_sig())
      assert agent.state.app.last_tags == [:outer, :inner]
    end
  end

  describe "runtime middleware injection" do
    test "options-supplied middleware appends to the compile-time chain", %{jido: jido} do
      pid =
        start_server(%{jido: jido}, MiddlewareAgent,
          middleware: [{TaggingMiddleware, %{tag: :runtime}}]
        )

      :ok = AgentServer.await_ready(pid)
      {:ok, agent} = AgentServer.call(pid, inspect_sig())
      assert :runtime in agent.state.app.last_tags
      assert agent.state.app.last_tags == [:outer, :inner, :runtime]
    end
  end
end
