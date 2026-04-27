defmodule Jido.AI.TestActions do
  @moduledoc false
  # Fixture action modules used by `Jido.AI.*` tests. Compiled in `:test`
  # only via `elixirc_paths(:test)`.
end

defmodule Jido.AI.TestActions.TestAdd do
  @moduledoc false
  use Jido.Action,
    name: "test_add",
    description: "Adds two integers and returns their sum.",
    schema: [
      a: [type: :integer, required: true, doc: "First addend"],
      b: [type: :integer, required: true, doc: "Second addend"]
    ]

  @impl true
  def run(%Jido.Signal{data: %{a: a, b: b}}, _slice, _opts, _ctx),
    do: {:ok, %{result: a + b}, []}
end

defmodule Jido.AI.TestActions.TestMultiply do
  @moduledoc false
  use Jido.Action,
    name: "test_multiply",
    description: "Multiplies two integers and returns their product.",
    schema: [
      a: [type: :integer, required: true, doc: "First factor"],
      b: [type: :integer, required: true, doc: "Second factor"]
    ]

  @impl true
  def run(%Jido.Signal{data: %{a: a, b: b}}, _slice, _opts, _ctx),
    do: {:ok, %{result: a * b}, []}
end

defmodule Jido.AI.TestActions.TestEcho do
  @moduledoc false
  use Jido.Action,
    name: "test_echo",
    description: "Echoes the input message back as the result.",
    schema: [
      message: [type: :string, required: true, doc: "The message to echo"]
    ]

  @impl true
  def run(%Jido.Signal{data: %{message: message}}, _slice, _opts, _ctx),
    do: {:ok, %{echo: message}, []}
end

defmodule Jido.AI.TestActions.TestFails do
  @moduledoc false
  use Jido.Action,
    name: "test_fails",
    description: "Always returns an error — used to exercise tool-failure paths.",
    schema: [
      reason: [type: :string, default: "test_failure", doc: "Failure reason"]
    ]

  @impl true
  def run(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx),
    do: {:error, reason}
end
