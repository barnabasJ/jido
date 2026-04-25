defmodule JidoTest.PluginTestAction do
  @moduledoc false
  use Jido.Action,
    name: "plugin_test_action",
    schema: []

  def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}}
end

defmodule JidoTest.PluginTestAnotherAction do
  @moduledoc false
  use Jido.Action,
    name: "plugin_test_another_action",
    schema: [value: [type: :integer, default: 0]]

  def run(%Jido.Signal{data: %{value: value}}, _slice, _opts, _ctx), do: {:ok, %{value: value}}
end

defmodule JidoTest.NotAnActionModule do
  @moduledoc false
  def some_function, do: :ok
end

defmodule JidoTest.TestActions do
  @moduledoc """
  Shared test actions for Jido test suite.
  """

  alias Jido.Action
  alias Jido.Agent.{Directive, StateOp}

  defmodule BasicAction do
    @moduledoc false
    use Action,
      name: "basic_action",
      description: "A basic action for testing",
      schema: [
        value: [type: :integer, required: true]
      ]

    def run(%Jido.Signal{data: %{value: value}}, _slice, _opts, _ctx) do
      {:ok, %{value: value}}
    end
  end

  defmodule NoSchema do
    @moduledoc false
    use Action,
      name: "no_schema",
      description: "Action with no schema"

    def run(%Jido.Signal{data: %{value: value}}, _slice, _opts, _ctx), do: {:ok, %{result: value + 2}}
    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{result: "No params"}}
  end

  defmodule Add do
    @moduledoc false
    use Action,
      name: "add",
      description: "Adds amount to value",
      schema: [
        value: [type: :integer, required: true],
        amount: [type: :integer, default: 1]
      ]

    def run(%Jido.Signal{data: %{value: value, amount: amount}}, _slice, _opts, _ctx) do
      {:ok, %{value: value + amount}}
    end
  end

  defmodule EmitAction do
    @moduledoc false
    use Action,
      name: "emit_action",
      description: "Action that returns an emit effect"

    def run(_signal, _slice, _opts, _ctx) do
      signal = %{type: "test.emitted", data: %{value: 42}}
      {:ok, %{emitted: true}, Directive.emit(signal)}
    end
  end

  defmodule MultiEffectAction do
    @moduledoc false
    use Action,
      name: "multi_effect_action",
      description: "Action that returns multiple effects"

    def run(_signal, _slice, _opts, _ctx) do
      effects = [
        Directive.emit(%{type: "event.1"}),
        Directive.schedule(1000, :check)
      ]

      {:ok, %{triggered: true}, effects}
    end
  end

  defmodule SetStateAction do
    @moduledoc false
    use Action,
      name: "set_state_action",
      description: "Action that uses StateOp.SetState"

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{primary: "result"}, %StateOp.SetState{attrs: %{extra: "state"}}}
    end
  end

  defmodule ReplaceStateAction do
    @moduledoc false
    use Action,
      name: "replace_state_action",
      description: "Action that uses StateOp.ReplaceState"

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, %StateOp.ReplaceState{state: %{replaced: true, fresh: "state"}}}
    end
  end

  defmodule DeleteKeysAction do
    @moduledoc false
    use Action,
      name: "delete_keys_action",
      description: "Action that uses StateOp.DeleteKeys"

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, %StateOp.DeleteKeys{keys: [:to_delete, :also_delete]}}
    end
  end

  defmodule SetPathAction do
    @moduledoc false
    use Action,
      name: "set_path_action",
      description: "Action that uses StateOp.SetPath"

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, %StateOp.SetPath{path: [:nested, :deep, :value], value: 42}}
    end
  end

  defmodule DeletePathAction do
    @moduledoc false
    use Action,
      name: "delete_path_action",
      description: "Action that uses StateOp.DeletePath"

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, %StateOp.DeletePath{path: [:nested, :to_remove]}}
    end
  end

  defmodule IncrementAction do
    @moduledoc "Action that increments the :counter state field"
    use Action,
      name: "increment",
      schema: [
        amount: [type: :integer, default: 1]
      ]

    def run(%Jido.Signal{data: %{amount: amount}}, slice, _opts, _ctx) do
      slice = if is_map(slice), do: slice, else: %{}
      count = Map.get(slice, :counter, 0)
      {:ok, Map.put(slice, :counter, count + amount)}
    end
  end

  defmodule DecrementAction do
    @moduledoc "Action that decrements the :counter state field"
    use Action,
      name: "decrement",
      schema: [
        amount: [type: :integer, default: 1]
      ]

    def run(%Jido.Signal{data: %{amount: amount}}, slice, _opts, _ctx) do
      slice = if is_map(slice), do: slice, else: %{}
      count = Map.get(slice, :counter, 0)
      {:ok, Map.put(slice, :counter, count - amount)}
    end
  end

  defmodule RecordAction do
    @moduledoc "Action that appends params to the :messages state field"
    use Action,
      name: "record",
      schema: [
        message: [type: :any, required: false]
      ]

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      messages = Map.get(slice, :messages, [])
      message = Map.get(params, :message, params)
      {:ok, %{messages: messages ++ [message]}}
    end
  end

  defmodule SlowAction do
    @moduledoc "Action that sleeps for a configurable delay"
    use Action,
      name: "slow",
      schema: [
        delay_ms: [type: :integer, default: 100]
      ]

    def run(%Jido.Signal{data: %{delay_ms: delay}}, _slice, _opts, _ctx) do
      Process.sleep(delay)
      {:ok, %{processed: true, delay: delay}}
    end
  end

  defmodule FailingAction do
    @moduledoc "Action that always fails with a configurable error message"
    use Action,
      name: "failing",
      schema: [
        reason: [type: :string, default: "intentional failure"]
      ]

    def run(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx) do
      {:error, reason}
    end
  end
end
