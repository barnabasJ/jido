defmodule Jido.Dsl.ScaffoldTest do
  use ExUnit.Case, async: true

  # The placeholders from task 0033 stay empty until the corresponding
  # surface migration lands. Task 0034 fills `Jido.Dsl.Agent` and
  # `Jido.Dsl.Instance`; the rest still scaffold-only.

  @placeholder_modules [
    Jido.Dsl.Slice,
    Jido.Dsl.Plugin,
    Jido.Dsl.Middleware,
    Jido.Dsl.Action,
    Jido.Dsl.Sensor
  ]

  @migrated_modules [
    Jido.Dsl.Agent,
    Jido.Dsl.Instance
  ]

  for module <- @placeholder_modules ++ @migrated_modules do
    test "#{inspect(module)} is a Spark.Dsl.Extension" do
      assert Spark.implements_behaviour?(unquote(module), Spark.Dsl.Extension)
    end
  end

  for module <- @placeholder_modules do
    test "#{inspect(module)} has an empty section list (filled by later tasks)" do
      assert unquote(module).sections() == []
    end
  end

  test "Jido.Dsl.Agent contributes the host-owned sections (task 0034)" do
    section_names = Enum.map(Jido.Dsl.Agent.sections(), & &1.name)
    assert :agent in section_names
    assert :signal_routes in section_names
    assert :schedules in section_names
  end

  test "Jido.Dsl.Instance contributes the `instance` section (task 0034)" do
    section_names = Enum.map(Jido.Dsl.Instance.sections(), & &1.name)
    assert :instance in section_names
  end
end
