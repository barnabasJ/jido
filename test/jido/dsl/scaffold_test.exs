defmodule Jido.Dsl.ScaffoldTest do
  use ExUnit.Case, async: true

  # All `Jido.Dsl.*` extensions are now filled in. Task 0034 wired
  # `Jido.Dsl.Agent` and `Jido.Dsl.Instance`. Task 0035 wired
  # `Jido.Dsl.Slice`, `Jido.Dsl.Plugin`, and `Jido.Dsl.Middleware`.
  # Task 0036 wired `Jido.Dsl.Action` and `Jido.Dsl.Sensor`.

  @migrated_modules [
    Jido.Dsl.Agent,
    Jido.Dsl.Instance,
    Jido.Dsl.Slice,
    Jido.Dsl.Plugin,
    Jido.Dsl.Middleware,
    Jido.Dsl.Action,
    Jido.Dsl.Sensor
  ]

  for module <- @migrated_modules do
    test "#{inspect(module)} is a Spark.Dsl.Extension" do
      assert Spark.implements_behaviour?(unquote(module), Spark.Dsl.Extension)
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

  test "Jido.Dsl.Slice contributes the slice surface sections (task 0035)" do
    section_names = Enum.map(Jido.Dsl.Slice.sections(), & &1.name)
    assert :slice in section_names
    assert :signal_routes in section_names
    assert :subscriptions in section_names
    assert :schedules in section_names
    assert :capabilities in section_names
    assert :requires in section_names
  end

  test "Jido.Dsl.Plugin re-exports Jido.Dsl.Slice.sections/0 (task 0035)" do
    assert Jido.Dsl.Plugin.sections() == Jido.Dsl.Slice.sections()
  end

  test "Jido.Dsl.Middleware contributes the `middleware` section (task 0035)" do
    section_names = Enum.map(Jido.Dsl.Middleware.sections(), & &1.name)
    assert :middleware in section_names
  end

  test "Jido.Dsl.Action contributes the `action` section (task 0036)" do
    section_names = Enum.map(Jido.Dsl.Action.sections(), & &1.name)
    assert :action in section_names
  end

  test "Jido.Dsl.Sensor contributes the `sensor` section (task 0036)" do
    section_names = Enum.map(Jido.Dsl.Sensor.sections(), & &1.name)
    assert :sensor in section_names
  end
end
