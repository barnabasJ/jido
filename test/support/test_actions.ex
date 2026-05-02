defmodule JidoTest.PluginTestAction do
  @moduledoc false
  use Jido.Action

  action do
    name "plugin_test_action"
    schema []
  end

  def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}, []}
end

defmodule JidoTest.PluginTestAnotherAction do
  @moduledoc false
  use Jido.Action

  action do
    name "plugin_test_another_action"
    schema value: [type: :integer, default: 0]
  end

  def run(%Jido.Signal{data: %{value: value}}, _slice, _opts, _ctx),
    do: {:ok, %{value: value}, []}
end

defmodule JidoTest.NotAnActionModule do
  @moduledoc false
  def some_function, do: :ok
end

defmodule JidoTest.TestActions do
  @moduledoc """
  Shared test actions for Jido test suite.
  """

  alias Jido.Agent.SliceUpdate
  alias Jido.Directives

  defmodule BasicAction do
    @moduledoc false
    use Jido.Action

    action do
      name "basic_action"
      description "A basic action for testing"
      schema value: [type: :integer, required: true]
    end

    def run(%Jido.Signal{data: %{value: value}}, _slice, _opts, _ctx) do
      {:ok, %{value: value}, []}
    end
  end

  defmodule NoSchema do
    @moduledoc false
    use Jido.Action

    action do
      name "no_schema"
      description "Action with no schema"
    end

    def run(%Jido.Signal{data: %{value: value}}, _slice, _opts, _ctx),
      do: {:ok, %{result: value + 2}, []}

    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{result: "No params"}, []}
  end

  defmodule Add do
    @moduledoc false
    use Jido.Action

    action do
      name "add"
      description "Adds amount to value"
      schema value: [type: :integer, required: true], amount: [type: :integer, default: 1]
    end

    def run(%Jido.Signal{data: %{value: value, amount: amount}}, _slice, _opts, _ctx) do
      {:ok, %{value: value + amount}, []}
    end
  end

  defmodule EmitAction do
    @moduledoc false
    use Jido.Action

    action do
      name "emit_action"
      description "Action that returns an emit effect"
    end

    def run(_signal, _slice, _opts, _ctx) do
      signal = %{type: "test.emitted", data: %{value: 42}}
      {:ok, %{emitted: true}, [Directives.emit(signal)]}
    end
  end

  defmodule MultiEffectAction do
    @moduledoc false
    use Jido.Action

    action do
      name "multi_effect_action"
      description "Action that returns multiple effects"
    end

    def run(_signal, _slice, _opts, _ctx) do
      effects = [
        Directives.emit(%{type: "event.1"}),
        Directives.schedule(1000, :check)
      ]

      {:ok, %{triggered: true}, effects}
    end
  end

  defmodule MultiSliceAction do
    @moduledoc false
    use Jido.Action

    action do
      name "multi_slice_action"
      description "Action that returns a SliceUpdate writing two slices in one turn"
    end

    def run(_signal, _slice, _opts, _ctx) do
      {:ok,
       %SliceUpdate{
         slices: %{
           domain: %{primary: "result"},
           audit: %{last_event: :touched}
         }
       }, []}
    end
  end

  defmodule IncrementAction do
    @moduledoc "Action that increments the :counter state field"
    use Jido.Action

    action do
      name "increment"
      schema amount: [type: :integer, default: 1]
    end

    def run(%Jido.Signal{data: %{amount: amount}}, slice, _opts, _ctx) do
      slice = if is_map(slice), do: slice, else: %{}
      count = Map.get(slice, :counter, 0)
      {:ok, Map.put(slice, :counter, count + amount), []}
    end
  end

  defmodule DecrementAction do
    @moduledoc "Action that decrements the :counter state field"
    use Jido.Action

    action do
      name "decrement"
      schema amount: [type: :integer, default: 1]
    end

    def run(%Jido.Signal{data: %{amount: amount}}, slice, _opts, _ctx) do
      slice = if is_map(slice), do: slice, else: %{}
      count = Map.get(slice, :counter, 0)
      {:ok, Map.put(slice, :counter, count - amount), []}
    end
  end

  defmodule RecordAction do
    @moduledoc "Action that appends params to the :messages state field"
    use Jido.Action

    action do
      name "record"
      schema message: [type: :any, required: false]
    end

    def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      messages = Map.get(slice, :messages, [])
      message = Map.get(params, :message, params)
      {:ok, %{messages: messages ++ [message]}, []}
    end
  end

  defmodule SlowAction do
    @moduledoc "Action that sleeps for a configurable delay"
    use Jido.Action

    action do
      name "slow"
      schema delay_ms: [type: :integer, default: 100]
    end

    def run(%Jido.Signal{data: %{delay_ms: delay}}, _slice, _opts, _ctx) do
      Process.sleep(delay)
      {:ok, %{processed: true, delay: delay}, []}
    end
  end

  defmodule FailingAction do
    @moduledoc "Action that always fails with a configurable error message"
    use Jido.Action

    action do
      name "failing"
      schema reason: [type: :string, default: "intentional failure"]
    end

    def run(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx) do
      {:error, reason}
    end
  end
end
