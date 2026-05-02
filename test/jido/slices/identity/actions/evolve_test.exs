defmodule JidoTest.Identity.Actions.EvolveTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Slices.Identity.Actions.Evolve
  alias Jido.Slices.Identity.State

  defp sig(data) do
    Signal.new!(%{type: "identity_evolve", source: "/test", data: data})
  end

  describe "run/4" do
    test "initializes identity when slice is nil" do
      assert {:ok, %State{} = evolved, []} =
               Evolve.run(sig(%{days: 0, years: 0}), nil, %{}, %{})

      assert evolved.profile[:age] == 0
    end

    test "evolves identity by years" do
      identity = State.new()

      assert {:ok, %State{} = evolved, []} =
               Evolve.run(sig(%{days: 0, years: 5}), identity, %{}, %{})

      assert evolved.profile[:age] == 5
    end

    test "evolves identity by days" do
      identity = State.new()

      assert {:ok, %State{} = evolved, []} =
               Evolve.run(sig(%{days: 730, years: 0}), identity, %{}, %{})

      assert evolved.profile[:age] == 2
    end

    test "evolves identity by combined years and days" do
      identity = State.new()

      assert {:ok, %State{} = evolved, []} =
               Evolve.run(sig(%{days: 365, years: 3}), identity, %{}, %{})

      assert evolved.profile[:age] == 4
    end

    test "bumps rev on evolve" do
      identity = State.new()
      assert identity.rev == 0

      assert {:ok, %State{} = evolved, []} =
               Evolve.run(sig(%{days: 0, years: 1}), identity, %{}, %{})

      assert evolved.rev == 1
    end
  end
end
