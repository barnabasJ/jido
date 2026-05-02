defmodule JidoTest.ThreadTest do
  use JidoTest.Case, async: true

  alias Jido.Slices.Thread.Entry
  alias Jido.Slices.Thread.State

  describe "Entry.new/1" do
    test "creates entry with defaults" do
      entry = Entry.new(%{})

      assert entry.seq == 0
      assert entry.kind == :note
      assert entry.payload == %{}
      assert entry.refs == %{}
      assert is_integer(entry.at)
    end

    test "creates entry from keyword list" do
      entry = Entry.new(kind: :message, payload: %{role: "user"})

      assert entry.kind == :message
      assert entry.payload == %{role: "user"}
    end

    test "creates entry with all attributes" do
      now = System.system_time(:millisecond)

      entry =
        Entry.new(%{
          id: "entry_123",
          seq: 5,
          at: now,
          kind: :tool_call,
          payload: %{name: "search"},
          refs: %{signal_id: "sig_1"}
        })

      assert entry.id == "entry_123"
      assert entry.seq == 5
      assert entry.at == now
      assert entry.kind == :tool_call
      assert entry.payload == %{name: "search"}
      assert entry.refs == %{signal_id: "sig_1"}
    end

    test "accepts string keys in map" do
      entry = Entry.new(%{"kind" => :error, "payload" => %{"msg" => "failed"}})

      assert entry.kind == :error
      assert entry.payload == %{"msg" => "failed"}
    end
  end

  describe "State.new/1" do
    test "creates empty thread with defaults" do
      thread = State.new()

      assert String.starts_with?(thread.id, "thread_")
      assert thread.rev == 0
      assert thread.entries == []
      assert is_integer(thread.created_at)
      assert is_integer(thread.updated_at)
      assert thread.metadata == %{}
      assert thread.stats == %{entry_count: 0}
    end

    test "accepts custom id" do
      thread = State.new(id: "my_thread")

      assert thread.id == "my_thread"
    end

    test "accepts custom metadata" do
      thread = State.new(metadata: %{user_id: "u1", session: "s1"})

      assert thread.metadata == %{user_id: "u1", session: "s1"}
    end

    test "accepts custom timestamp via now option" do
      fixed_time = 1_700_000_000_000
      thread = State.new(now: fixed_time)

      assert thread.created_at == fixed_time
      assert thread.updated_at == fixed_time
    end
  end

  describe "State.append/2" do
    test "appends single entry as map" do
      thread =
        State.new()
        |> State.append(%{kind: :message, payload: %{content: "hello"}})

      assert State.entry_count(thread) == 1
      assert thread.rev == 1

      entry = State.last(thread)
      assert entry.seq == 0
      assert entry.kind == :message
      assert entry.payload == %{content: "hello"}
    end

    test "appends Entry struct" do
      entry = Entry.new(kind: :note, payload: %{text: "annotation"})

      thread =
        State.new()
        |> State.append(entry)

      assert State.entry_count(thread) == 1

      appended = State.last(thread)
      assert appended.kind == :note
      assert appended.seq == 0
    end

    test "appends multiple entries as list" do
      entries = [
        %{kind: :message, payload: %{role: "user"}},
        %{kind: :message, payload: %{role: "assistant"}}
      ]

      thread =
        State.new()
        |> State.append(entries)

      assert State.entry_count(thread) == 2
      assert thread.rev == 2

      [first, second] = State.to_list(thread)
      assert first.seq == 0
      assert second.seq == 1
    end

    test "assigns monotonically increasing seq" do
      thread =
        State.new()
        |> State.append(%{kind: :message})
        |> State.append(%{kind: :message})
        |> State.append(%{kind: :message})

      seqs = thread |> State.to_list() |> Enum.map(& &1.seq)
      assert seqs == [0, 1, 2]
    end

    test "increments rev on each append" do
      thread = State.new()
      assert thread.rev == 0

      thread = State.append(thread, %{kind: :message})
      assert thread.rev == 1

      thread = State.append(thread, [%{kind: :message}, %{kind: :message}])
      assert thread.rev == 3
    end

    test "updates updated_at timestamp" do
      old_time = 1_700_000_000_000
      thread = State.new(now: old_time)

      Process.sleep(1)
      thread = State.append(thread, %{kind: :message})

      assert thread.updated_at > old_time
    end

    test "generates entry id if not provided" do
      thread =
        State.new()
        |> State.append(%{kind: :message})

      entry = State.last(thread)
      assert String.starts_with?(entry.id, "entry_")
    end

    test "preserves provided entry id" do
      thread =
        State.new()
        |> State.append(%{id: "custom_id", kind: :message})

      entry = State.last(thread)
      assert entry.id == "custom_id"
    end
  end

  describe "State.entry_count/1" do
    test "returns 0 for empty thread" do
      thread = State.new()
      assert State.entry_count(thread) == 0
    end

    test "returns correct count after appends" do
      thread =
        State.new()
        |> State.append(%{kind: :message})
        |> State.append([%{kind: :message}, %{kind: :message}])

      assert State.entry_count(thread) == 3
    end
  end

  describe "State.last/1" do
    test "returns nil for empty thread" do
      thread = State.new()
      assert State.last(thread) == nil
    end

    test "returns last appended entry" do
      thread =
        State.new()
        |> State.append(%{kind: :message, payload: %{n: 1}})
        |> State.append(%{kind: :message, payload: %{n: 2}})

      last = State.last(thread)
      assert last.payload == %{n: 2}
      assert last.seq == 1
    end
  end

  describe "State.get_entry/2" do
    test "returns nil for non-existent seq" do
      thread = State.new()
      assert State.get_entry(thread, 0) == nil
    end

    test "returns entry by seq" do
      thread =
        State.new()
        |> State.append(%{kind: :message, payload: %{n: 0}})
        |> State.append(%{kind: :message, payload: %{n: 1}})
        |> State.append(%{kind: :message, payload: %{n: 2}})

      entry = State.get_entry(thread, 1)
      assert entry.payload == %{n: 1}
      assert entry.seq == 1
    end
  end

  describe "State.to_list/1" do
    test "returns empty list for empty thread" do
      thread = State.new()
      assert State.to_list(thread) == []
    end

    test "returns all entries in order" do
      thread =
        State.new()
        |> State.append(%{kind: :a})
        |> State.append(%{kind: :b})
        |> State.append(%{kind: :c})

      kinds = thread |> State.to_list() |> Enum.map(& &1.kind)
      assert kinds == [:a, :b, :c]
    end
  end

  describe "State.filter_by_kind/2" do
    test "returns empty list for missing thread" do
      assert State.filter_by_kind(nil, :message) == []
    end

    test "raises for invalid thread input" do
      malformed_thread = :erlang.binary_to_term(:erlang.term_to_binary(%{}))

      assert_raise FunctionClauseError, fn ->
        State.filter_by_kind(malformed_thread, :message)
      end
    end

    test "returns empty list when no matches" do
      thread =
        State.new()
        |> State.append(%{kind: :message})

      assert State.filter_by_kind(thread, :tool_call) == []
    end

    test "filters by single kind" do
      thread =
        State.new()
        |> State.append(%{kind: :message})
        |> State.append(%{kind: :tool_call})
        |> State.append(%{kind: :message})

      messages = State.filter_by_kind(thread, :message)
      assert length(messages) == 2
      assert Enum.all?(messages, &(&1.kind == :message))
    end

    test "filters by multiple kinds" do
      thread =
        State.new()
        |> State.append(%{kind: :message})
        |> State.append(%{kind: :tool_call})
        |> State.append(%{kind: :tool_result})
        |> State.append(%{kind: :note})

      tools = State.filter_by_kind(thread, [:tool_call, :tool_result])
      assert length(tools) == 2
      assert Enum.all?(tools, &(&1.kind in [:tool_call, :tool_result]))
    end
  end

  describe "State.slice/3" do
    test "returns empty list for empty thread" do
      thread = State.new()
      assert State.slice(thread, 0, 10) == []
    end

    test "returns entries in seq range inclusive" do
      thread =
        State.new()
        |> State.append(%{kind: :a})
        |> State.append(%{kind: :b})
        |> State.append(%{kind: :c})
        |> State.append(%{kind: :d})
        |> State.append(%{kind: :e})

      sliced = State.slice(thread, 1, 3)
      assert length(sliced) == 3

      kinds = Enum.map(sliced, & &1.kind)
      assert kinds == [:b, :c, :d]
    end

    test "handles out of bounds gracefully" do
      thread =
        State.new()
        |> State.append(%{kind: :a})
        |> State.append(%{kind: :b})

      sliced = State.slice(thread, 5, 10)
      assert sliced == []
    end

    test "handles partial overlap" do
      thread =
        State.new()
        |> State.append(%{kind: :a})
        |> State.append(%{kind: :b})
        |> State.append(%{kind: :c})

      sliced = State.slice(thread, 1, 100)
      assert length(sliced) == 2

      kinds = Enum.map(sliced, & &1.kind)
      assert kinds == [:b, :c]
    end
  end

  describe "immutability" do
    test "append returns new thread without modifying original" do
      original = State.new()
      updated = State.append(original, %{kind: :message})

      assert State.entry_count(original) == 0
      assert State.entry_count(updated) == 1
    end
  end
end
