defmodule JidoExampleTest.ThreadSliceTest do
  @moduledoc """
  Example test demonstrating Thread as a default slice and conversation history patterns.

  This test shows:
  - Every agent gets `Jido.Thread.Slice` automatically (default singleton slice)
  - Initializing and appending to thread through `Jido.Thread.Actions.{Ensure,
    Append}` via `cmd/2`
  - Reading thread directly off `agent.state[:thread]` and via `Jido.Thread`
    read-only functions
  - Disabling the thread slice with `default_slices: %{thread: false}`
  - The strategy layer auto-tracks instruction_start/instruction_end when thread exists

  Run with: mix test --include example
  """
  use JidoTest.Case, async: false

  @moduletag :example
  @moduletag timeout: 15_000

  alias Jido.AgentServer
  alias Jido.Thread

  # ===========================================================================
  # ACTIONS: Conversation history via Thread
  # ===========================================================================

  defmodule RecordMessageAction do
    @moduledoc false
    use Jido.Action

    action do
      name "record_message"
      path :thread
      schema role: [type: :string, required: true], content: [type: :string, required: true]
    end

    def run(%Jido.Signal{data: %{role: role, content: content}}, slice, _opts, _ctx) do
      thread =
        case slice do
          %Thread{} = t -> t
          _ -> Thread.new()
        end

      entry = %{kind: :message, payload: %{role: role, content: content}}
      {:ok, Thread.append(thread, entry), []}
    end
  end

  defmodule SummarizeAction do
    @moduledoc false
    use Jido.Action

    action do
      name "summarize"
      path :domain
      schema []
    end

    def run(_signal, slice, _opts, ctx) do
      thread = Map.get(ctx[:agent].state, :thread)

      message_count =
        case thread do
          nil -> 0
          t -> length(Thread.filter_by_kind(t, :message))
        end

      {:ok, Map.put(slice, :summary, "#{message_count} messages in thread"), []}
    end
  end

  # ===========================================================================
  # AGENTS
  # ===========================================================================

  defmodule ChatAgent do
    @moduledoc false
    use Jido.Agent

    agent do
      name "chat_agent"
      path :domain
      description "Agent with default thread slice for conversation history"
      schema summary: [type: :string, default: nil]
    end

    signal_routes do
      route "record_message", RecordMessageAction
      route "summarize", SummarizeAction
    end
  end

  defmodule StatelessAgent do
    @moduledoc false
    use Jido.Agent,
      default_slices: %{thread: false}

    agent do
      name "stateless_agent"
      path :domain
      description "Agent with thread slice explicitly disabled"
      schema value: [type: :integer, default: 0]
    end
  end

  # ===========================================================================
  # TESTS
  # ===========================================================================

  describe "thread slice is a default singleton" do
    test "new agent has no thread until initialized on demand" do
      agent = ChatAgent.new()

      assert is_nil(agent.state[:thread])
    end

    test "Ensure action initializes thread on demand" do
      agent = ChatAgent.new()

      {:ok, agent, []} =
        ChatAgent.cmd(agent, {Jido.Thread.Actions.Ensure, %{metadata: %{user_id: "u1"}}})

      assert %Thread{} = agent.state[:thread]
      assert agent.state.thread.metadata == %{user_id: "u1"}
      assert Thread.entry_count(agent.state.thread) == 0
    end
  end

  describe "action-based thread manipulation" do
    test "action can initialize and append to thread" do
      agent = ChatAgent.new()

      {:ok, agent, []} =
        ChatAgent.cmd(agent, {RecordMessageAction, %{role: "user", content: "hello"}})

      assert %Thread{} = agent.state[:thread]

      messages = Thread.filter_by_kind(agent.state.thread, :message)
      assert length(messages) == 1

      [entry] = messages
      assert entry.kind == :message
      assert entry.payload.role == "user"
      assert entry.payload.content == "hello"
    end

    test "thread accumulates message entries across multiple actions" do
      agent = ChatAgent.new()

      {:ok, agent, []} =
        ChatAgent.cmd(agent, {RecordMessageAction, %{role: "user", content: "hi"}})

      {:ok, agent, []} =
        ChatAgent.cmd(agent, {RecordMessageAction, %{role: "assistant", content: "hello!"}})

      {:ok, agent, []} =
        ChatAgent.cmd(agent, {RecordMessageAction, %{role: "user", content: "how are you?"}})

      messages = Thread.filter_by_kind(agent.state.thread, :message)
      assert length(messages) == 3

      roles = Enum.map(messages, & &1.payload.role)
      assert roles == ["user", "assistant", "user"]

      thread = agent.state.thread
      assert Thread.entry_count(thread) == 3

      {:ok, agent, []} = ChatAgent.cmd(agent, SummarizeAction)
      assert agent.state.domain.summary == "3 messages in thread"
    end
  end

  describe "disabling thread slice" do
    test "agent with default_slices: %{thread: false} has no thread capability" do
      agent = StatelessAgent.new()

      assert is_nil(agent.state[:thread])
      refute Map.has_key?(agent.state, :thread)
    end
  end

  describe "appending via Thread.Actions.Append" do
    test "Append action creates thread and adds entries" do
      agent = ChatAgent.new()

      {:ok, agent, []} =
        ChatAgent.cmd(
          agent,
          {Jido.Thread.Actions.Append,
           %{entry: %{kind: :message, payload: %{role: "system", content: "init"}}}}
        )

      assert %Thread{} = agent.state[:thread]
      assert Thread.entry_count(agent.state.thread) == 1

      {:ok, agent, []} =
        ChatAgent.cmd(
          agent,
          {Jido.Thread.Actions.Append,
           %{
             entry: [
               %{kind: :message, payload: %{role: "user", content: "q1"}},
               %{kind: :message, payload: %{role: "assistant", content: "a1"}}
             ]
           }}
        )

      thread = agent.state.thread
      assert Thread.entry_count(thread) == 3

      entries = Thread.to_list(thread)
      contents = Enum.map(entries, & &1.payload.content)
      assert contents == ["init", "q1", "a1"]
    end
  end

  describe "thread via AgentServer" do
    test "thread persists across signals in a running server", %{jido: jido} do
      {:ok, pid} = Jido.start_agent(jido, ChatAgent, id: unique_id("chat"))

      {:ok, _agent} =
        AgentServer.call(
          pid,
          signal("record_message", %{role: "user", content: "first message"}),
          fn s -> {:ok, s.agent} end
        )

      {:ok, _agent} =
        AgentServer.call(
          pid,
          signal("record_message", %{role: "assistant", content: "first reply"}),
          fn s -> {:ok, s.agent} end
        )

      {:ok, agent} =
        AgentServer.call(pid, signal("summarize"), fn s -> {:ok, s.agent} end)

      assert agent.state.domain.summary == "2 messages in thread"
    end
  end
end
