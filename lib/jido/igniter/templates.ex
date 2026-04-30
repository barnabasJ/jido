defmodule Jido.Igniter.Templates do
  @moduledoc false
  # Template generators for Jido Igniter mix tasks

  @doc """
  Returns the template for an Agent module.
  """
  @spec agent_template(module :: String.t(), name :: String.t()) :: String.t()
  def agent_template(module, name), do: agent_template(module, name, plugins: [])

  @doc """
  Returns the template for an Agent module with optional plugin attachments.
  """
  @spec agent_template(module :: String.t(), name :: String.t(), opts :: keyword()) :: String.t()
  def agent_template(module, name, opts) do
    plugins = Keyword.get(opts, :plugins, [])
    slices_block = format_slices_block(plugins)

    """
    defmodule #{module} do
      @moduledoc \"\"\"
      TODO: Describe this agent.

      User-domain fields declared in `schema:` live under the agent's
      declared `path:` slice of `agent.state` — e.g. with `path: :domain`,
      a `:counter` field is read as `agent.state.domain.counter`.
      \"\"\"

      use Jido.Agent

      agent do
        name "#{name}"
        description "TODO: Add description"
        path :domain
        schema []
      end#{slices_block}
    end
    """
  end

  @doc """
  Returns the template for an Agent test module.
  """
  @spec agent_test_template(module :: String.t(), test_module :: String.t()) :: String.t()
  def agent_test_template(module, test_module) do
    alias_name = module_alias(module)

    """
    defmodule #{test_module} do
      use ExUnit.Case, async: true

      alias Jido.Dsl.Agent.Info, as: AgentInfo
      alias #{module}

      describe "new/1" do
        test "creates agent with default state" do
          agent = #{alias_name}.new()
          assert agent.name == AgentInfo.name(#{alias_name})
        end

        test "creates agent with custom id" do
          agent = #{alias_name}.new(id: "custom-id")
          assert agent.id == "custom-id"
        end
      end
    end
    """
  end

  @doc """
  Returns the template for a Plugin module.
  """
  @spec plugin_template(
          module :: String.t(),
          name :: String.t(),
          path :: String.t(),
          signal_routes :: [String.t()]
        ) :: String.t()
  def plugin_template(module, name, _path, signal_routes) do
    routes_block =
      signal_routes
      |> Enum.map_join("\n", fn type -> "    route #{inspect(type)}, :todo" end)

    """
    defmodule #{module} do
      use Jido.Plugin

      slice do
        name "#{name}"
        schema Zoi.object(%{})
      end

      signal_routes do
    #{routes_block}
      end
    end
    """
  end

  @doc """
  Returns the template for a Plugin test module.
  """
  @spec plugin_test_template(module :: String.t(), test_module :: String.t()) :: String.t()
  def plugin_test_template(module, test_module) do
    alias_name = module_alias(module)

    """
    defmodule #{test_module} do
      use ExUnit.Case, async: true

      alias Jido.Dsl.Plugin.Info, as: PluginInfo
      alias #{module}

      describe "Plugin.Info introspection" do
        test "exposes the configured name" do
          assert is_binary(PluginInfo.name(#{alias_name}))
        end
      end
    end
    """
  end

  @doc """
  Returns the template for a Sensor module.
  """
  @spec sensor_template(module :: String.t(), name :: String.t(), interval :: pos_integer()) ::
          String.t()
  def sensor_template(module, name, interval) do
    """
    defmodule #{module} do
      use Jido.Sensor

      sensor do
        name "#{name}"
        description "TODO: Add description"

        schema(
          Zoi.object(%{
            interval: Zoi.integer() |> Zoi.default(#{interval})
          })
        )
      end

      @impl true
      def init(config, _context) do
        interval = config[:interval] || #{interval}
        {:ok, %{interval: interval}, [{:schedule, interval}]}
      end

      @impl true
      def handle_event(:poll, state) do
        # TODO: Implement polling logic
        {:ok, state, []}
      end
    end
    """
  end

  @doc """
  Returns the template for a Sensor test module.
  """
  @spec sensor_test_template(module :: String.t(), test_module :: String.t()) :: String.t()
  def sensor_test_template(module, test_module) do
    alias_name = module_alias(module)

    """
    defmodule #{test_module} do
      use ExUnit.Case, async: true

      alias #{module}

      describe "init/2" do
        test "initializes with default interval" do
          assert {:ok, state, directives} = #{alias_name}.init(%{}, %{})
          assert is_map(state)
          assert is_list(directives)
        end
      end

      describe "handle_event/2" do
        test "handles poll event" do
          {:ok, state, _} = #{alias_name}.init(%{}, %{})
          assert {:ok, _state, signals} = #{alias_name}.handle_event(:poll, state)
          assert is_list(signals)
        end
      end
    end
    """
  end

  defp format_slices_block([]), do: ""

  defp format_slices_block(plugins) do
    lines =
      Enum.map_join(plugins, "\n", fn plugin ->
        "    slice :#{slice_path_for(plugin)}, #{inspect(plugin)}"
      end)

    "\n\n  slices do\n#{lines}\n  end"
  end

  defp slice_path_for(plugin) when is_atom(plugin) do
    # Default heuristic: use the plugin's last namespace segment lowercased
    # as the slice path. Users can edit the generated `slice :path, Module`
    # line to assign a different mount path.
    plugin
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp module_alias(module) do
    module
    |> String.split(".")
    |> List.last()
  end
end
