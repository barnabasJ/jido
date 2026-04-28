defmodule Jido.Dsl.ScaffoldTest do
  use ExUnit.Case, async: true

  for module <- [
        Jido.Dsl.Agent,
        Jido.Dsl.Slice,
        Jido.Dsl.Plugin,
        Jido.Dsl.Middleware,
        Jido.Dsl.Action,
        Jido.Dsl.Sensor,
        Jido.Dsl.Instance
      ] do
    test "#{inspect(module)} is a Spark.Dsl.Extension" do
      assert Spark.implements_behaviour?(unquote(module), Spark.Dsl.Extension)
    end

    test "#{inspect(module)} has an empty section list (filled by later tasks)" do
      assert unquote(module).sections() == []
    end
  end
end
