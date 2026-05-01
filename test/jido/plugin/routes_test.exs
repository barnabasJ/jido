defmodule JidoTest.Plugin.RoutesTest do
  use ExUnit.Case, async: true

  alias Jido.Plugin.Instance
  alias Jido.Plugin.Routes

  defmodule TestAction1 do
    @moduledoc false
    use Jido.Action

    action do
      name "test_action_1"
      schema []
    end

    @impl true
    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}, []}
  end

  defmodule TestAction2 do
    @moduledoc false
    use Jido.Action

    action do
      name "test_action_2"
      schema []
    end

    @impl true
    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}, []}
  end

  defmodule TestAction3 do
    @moduledoc false
    use Jido.Action

    action do
      name "test_action_3"
      schema []
    end

    @impl true
    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}, []}
  end

  defmodule PluginWithRoutes do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_with_routes"
    end

    signal_routes do
      route "post", TestAction1
      route "list", TestAction2
    end
  end

  defmodule PluginWithRoutesAndOptions do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_with_opts"
    end

    signal_routes do
      route "post", TestAction1, priority: 5
      route "list", TestAction2, on_conflict: :replace
    end
  end

  defmodule PluginNoRoutes do
    @moduledoc false
    use Jido.Plugin

    slice do
      name "plugin_no_routes"
    end
  end

  describe "expand_routes/1" do
    test "expands routes with prefix from instance" do
      instance = Instance.new(PluginWithRoutes, :test)

      routes = Routes.expand_routes(instance)

      assert length(routes) == 2
      assert {"plugin_with_routes.post", TestAction1, []} in routes
      assert {"plugin_with_routes.list", TestAction2, []} in routes
    end

    test "preserves route options" do
      instance = Instance.new(PluginWithRoutesAndOptions, :test)

      routes = Routes.expand_routes(instance)

      assert length(routes) == 2
      assert {"plugin_with_opts.post", TestAction1, [priority: 5]} in routes
      assert {"plugin_with_opts.list", TestAction2, [on_conflict: :replace]} in routes
    end

    test "applies alias prefix when using :as option" do
      instance = Instance.new({PluginWithRoutes, as: :support}, :test)

      routes = Routes.expand_routes(instance)

      assert length(routes) == 2
      assert {"support.plugin_with_routes.post", TestAction1, []} in routes
      assert {"support.plugin_with_routes.list", TestAction2, []} in routes
    end

    test "returns empty list when no routes and no patterns" do
      instance = Instance.new(PluginNoRoutes, :test)

      routes = Routes.expand_routes(instance)

      assert routes == []
    end

    test "returns the plugin's section-declared routes prefixed by route_prefix" do
      defmodule PluginWithSectionRoutes do
        @moduledoc false
        use Jido.Plugin

        slice do
          name "section_routes"
        end

        signal_routes do
          route "custom.route", TestAction1
        end
      end

      instance = Instance.new(PluginWithSectionRoutes, :test)
      routes = Routes.expand_routes(instance)

      assert routes == [{"section_routes.custom.route", TestAction1, []}]
    end
  end

  describe "detect_conflicts/1" do
    test "returns ok when no conflicts" do
      routes = [
        {"slack.post", TestAction1, []},
        {"slack.list", TestAction2, []}
      ]

      assert {:ok, merged} = Routes.detect_conflicts(routes)
      assert length(merged) == 2
      assert {"slack.post", TestAction1, -10} in merged
      assert {"slack.list", TestAction2, -10} in merged
    end

    test "returns error when same path with same priority" do
      routes = [
        {"slack.post", TestAction1, []},
        {"slack.post", TestAction2, []}
      ]

      assert {:error, conflicts} = Routes.detect_conflicts(routes)
      assert length(conflicts) == 1
      assert hd(conflicts) =~ "Route conflict: 'slack.post'"
      assert hd(conflicts) =~ "same priority -10"
    end

    test "higher priority wins when different priorities" do
      routes = [
        {"slack.post", TestAction1, [priority: -10]},
        {"slack.post", TestAction2, [priority: 5]}
      ]

      assert {:ok, merged} = Routes.detect_conflicts(routes)
      assert length(merged) == 1
      assert {"slack.post", TestAction2, 5} in merged
    end

    test "on_conflict: :replace bypasses conflict error" do
      routes = [
        {"slack.post", TestAction1, []},
        {"slack.post", TestAction2, [on_conflict: :replace]}
      ]

      assert {:ok, merged} = Routes.detect_conflicts(routes)
      assert length(merged) == 1
      assert {"slack.post", TestAction2, -10} in merged
    end

    test "on_conflict: :replace with higher priority wins" do
      routes = [
        {"slack.post", TestAction1, [priority: 5, on_conflict: :replace]},
        {"slack.post", TestAction2, [on_conflict: :replace]}
      ]

      assert {:ok, merged} = Routes.detect_conflicts(routes)
      assert length(merged) == 1
      assert {"slack.post", TestAction1, 5} in merged
    end

    test "multiple conflicts are all reported" do
      routes = [
        {"slack.post", TestAction1, []},
        {"slack.post", TestAction2, []},
        {"slack.list", TestAction1, []},
        {"slack.list", TestAction3, []}
      ]

      assert {:error, conflicts} = Routes.detect_conflicts(routes)
      assert length(conflicts) == 2
      assert Enum.any?(conflicts, &(&1 =~ "'slack.post'"))
      assert Enum.any?(conflicts, &(&1 =~ "'slack.list'"))
    end

    test "applies default priority of -10" do
      routes = [{"slack.post", TestAction1, []}]

      assert {:ok, [{"slack.post", TestAction1, -10}]} = Routes.detect_conflicts(routes)
    end

    test "explicit priority overrides default" do
      routes = [{"slack.post", TestAction1, [priority: 0]}]

      assert {:ok, [{"slack.post", TestAction1, 0}]} = Routes.detect_conflicts(routes)
    end
  end

  describe "default_priority/0" do
    test "returns -10" do
      assert Routes.default_priority() == -10
    end
  end

  describe "integration: expand and detect" do
    test "two instances of same plugin with different :as don't conflict" do
      support = Instance.new({PluginWithRoutes, as: :support}, :test)
      sales = Instance.new({PluginWithRoutes, as: :sales}, :test)

      support_routes = Routes.expand_routes(support)
      sales_routes = Routes.expand_routes(sales)

      all_routes = support_routes ++ sales_routes

      assert {:ok, merged} = Routes.detect_conflicts(all_routes)
      assert length(merged) == 4
    end

    test "same plugin mounted twice produces deduped routes (no conflict)" do
      # Post-task-0062: mounting the same plugin at multiple paths is the
      # multi-instance fan-out case. The route tuples are identical
      # (same prefix, same target, same priority); detect_conflicts/1
      # collapses them and runtime fan-out at `cmd/2` carries the
      # per-mount semantics.
      instance1 = Instance.new(PluginWithRoutes, :test)
      instance2 = Instance.new(PluginWithRoutes, :test)

      routes1 = Routes.expand_routes(instance1)
      routes2 = Routes.expand_routes(instance2)

      all_routes = routes1 ++ routes2

      assert {:ok, merged} = Routes.detect_conflicts(all_routes)
      # PluginWithRoutes contributes 2 distinct routes; mounting twice
      # still yields 2 deduped entries (one per route).
      assert length(merged) == 2
    end
  end
end
