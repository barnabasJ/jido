defmodule Jido.AI.Directive.ToolExecTest do
  use JidoTest.Case, async: true

  alias Jido.AI.Directive.ToolExec
  alias Jido.AI.TestActions.{TestAdd, TestFails}

  defp directive(opts \\ []) do
    call =
      Keyword.get(opts, :tool_call, %{
        id: "call_1",
        name: "test_add",
        arguments: %{"a" => 1, "b" => 2}
      })

    %ToolExec{
      tool_call: call,
      tool_modules: Keyword.get(opts, :tool_modules, [TestAdd, TestFails]),
      request_id: Keyword.get(opts, :request_id, "req_1")
    }
  end

  defp fake_state(jido), do: %{id: "stub-agent", jido: jido}

  defp spawn_agent_stub(target_pid) do
    spawn_link(fn -> forward(target_pid) end)
  end

  defp forward(target) do
    receive do
      {:"$gen_cast", {:signal, signal}} ->
        send(target, {:cast, signal})
        forward(target)

      {:run, fun, from} ->
        send(from, {:run_done, fun.()})
        forward(target)

      _ ->
        forward(target)
    end
  end

  defp run_in(pid, fun) do
    send(pid, {:run, fun, self()})

    receive do
      {:run_done, result} -> result
    after
      1_000 -> :timeout
    end
  end

  test "runs the tool and casts ai.react.tool.completed with JSON-encoded result",
       %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)

    :ok =
      run_in(agent, fn ->
        Jido.AgentServer.DirectiveExec.exec(directive(), :input_signal, fake_state(jido))
      end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "ai.react.tool.completed"
    assert signal.data.tool_call_id == "call_1"
    assert signal.data.name == "test_add"
    assert signal.data.request_id == "req_1"
    assert Jason.decode!(signal.data.content) == %{"result" => 3}
  end

  test "returns the tool's {:error, _} as JSON inside tool.completed (not failed)",
       %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)

    failing =
      directive(tool_call: %{id: "call_2", name: "test_fails", arguments: %{"reason" => "nope"}})

    :ok =
      run_in(agent, fn ->
        Jido.AgentServer.DirectiveExec.exec(failing, :input_signal, fake_state(jido))
      end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "ai.react.tool.completed"
    assert Jason.decode!(signal.data.content) == %{"error" => "nope"}
  end

  test "encodes a 'tool not found' error when no module matches", %{jido: jido} do
    test_pid = self()
    agent = spawn_agent_stub(test_pid)

    missing =
      directive(tool_call: %{id: "call_3", name: "ghost", arguments: %{}})

    :ok =
      run_in(agent, fn ->
        Jido.AgentServer.DirectiveExec.exec(missing, :input_signal, fake_state(jido))
      end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "ai.react.tool.completed"
    assert Jason.decode!(signal.data.content) == %{"error" => "tool not found: ghost"}
  end
end
