defmodule Jido.Discovery do
  @moduledoc """
  Fast, persistent catalog of Jido components (Actions, Sensors, Agents, Slices, Demos).

  Discovery uses `:persistent_term` for optimal read performance. The catalog is built
  asynchronously during application startup and can be refreshed on demand.

  ## Component Discovery

  Discovery walks every loaded application's modules and identifies Jido
  components by their Spark host kind:

  - **Actions** — `Spark.Dsl.is?(mod, Jido.Action)`
  - **Sensors** — `Spark.Dsl.is?(mod, Jido.Sensor)`
  - **Agents** — `Spark.Dsl.is?(mod, Jido.Agent)`
  - **Slices** — `Spark.Dsl.is?(mod, Jido.Slice)`
  - **Demos** — `__jido_demo__/0` marker (kept as a one-off; demos are
    not yet a Spark host on their own)

  ## Component Metadata

  Each discovered component includes:

  ```elixir
  %{
    module: MyApp.CoolAction,
    name: "cool_action",
    description: "Does cool stuff",
    slug: "abc123de",
    category: :utility,
    tags: [:cool, :stuff]
  }
  ```

  ## Usage

      # List components with optional filters
      Jido.Discovery.list_actions(category: :utility, limit: 10)
      Jido.Discovery.list_sensors(tag: :monitoring)

      # Find by slug
      Jido.Discovery.get_action_by_slug("abc123de")

      # Refresh catalog
      Jido.Discovery.refresh()

      # Get last update time
      {:ok, timestamp} = Jido.Discovery.last_updated()

  ## Filtering Options

  - `:limit` - Maximum results to return
  - `:offset` - Results to skip (pagination)
  - `:name` - Filter by name (partial match)
  - `:description` - Filter by description (partial match)
  - `:category` - Filter by category (exact match)
  - `:tag` - Filter by tag (must have exact tag)

  Filters use AND logic - all specified filters must match.

  ## Performance

  Reads are extremely fast (direct memory access) and never block.
  All processes can read concurrently without contention.
  """

  alias Jido.Dsl.Action.Info, as: ActionInfo
  alias Jido.Dsl.Agent.Info, as: AgentInfo
  alias Jido.Dsl.Sensor.Info, as: SensorInfo
  alias Jido.Dsl.Slice.Info, as: SliceInfo

  @catalog_key :jido_discovery_catalog

  @type component_type :: :actions | :sensors | :agents | :slices | :demos
  @type component_metadata :: %{
          module: module(),
          name: String.t(),
          description: String.t(),
          slug: String.t(),
          category: atom() | nil,
          tags: [atom()] | nil
        }

  # Initialization

  @doc """
  Initializes the discovery catalog asynchronously.

  Call this from your application supervisor's start callback.
  The catalog will be built in the background without blocking startup.
  """
  @spec init_async() :: Task.t()
  def init_async do
    Task.async(fn ->
      catalog = build_catalog()
      :persistent_term.put(@catalog_key, catalog)
      :ok
    end)
  end

  # Public API

  @doc """
  Refreshes the component catalog by rescanning all loaded applications.
  """
  @spec refresh() :: :ok
  def refresh do
    catalog = build_catalog()
    :persistent_term.put(@catalog_key, catalog)
    :ok
  end

  @doc """
  Returns the last time the catalog was updated.
  """
  @spec last_updated() :: {:ok, DateTime.t()} | {:error, :not_initialized}
  def last_updated do
    case get_catalog() do
      {:ok, catalog} -> {:ok, catalog.last_updated}
      error -> error
    end
  end

  @doc """
  Returns the full catalog for inspection.
  """
  @spec catalog() :: {:ok, map()} | {:error, :not_initialized}
  def catalog do
    get_catalog()
  end

  # Listing components

  @doc """
  Lists all Actions with optional filtering and pagination.
  """
  @spec list_actions(keyword()) :: [component_metadata()]
  def list_actions(opts \\ []), do: list(:actions, opts)

  @doc """
  Lists all Sensors with optional filtering and pagination.
  """
  @spec list_sensors(keyword()) :: [component_metadata()]
  def list_sensors(opts \\ []), do: list(:sensors, opts)

  @doc """
  Lists all Agents with optional filtering and pagination.
  """
  @spec list_agents(keyword()) :: [component_metadata()]
  def list_agents(opts \\ []), do: list(:agents, opts)

  @doc """
  Lists all Slices with optional filtering and pagination.
  """
  @spec list_slices(keyword()) :: [component_metadata()]
  def list_slices(opts \\ []), do: list(:slices, opts)

  @doc """
  Lists all Demos with optional filtering and pagination.
  """
  @spec list_demos(keyword()) :: [component_metadata()]
  def list_demos(opts \\ []), do: list(:demos, opts)

  # Finding by slug

  @doc """
  Retrieves an Action by its slug.
  """
  @spec get_action_by_slug(String.t()) :: component_metadata() | nil
  def get_action_by_slug(slug), do: get_by_slug(:actions, slug)

  @doc """
  Retrieves a Sensor by its slug.
  """
  @spec get_sensor_by_slug(String.t()) :: component_metadata() | nil
  def get_sensor_by_slug(slug), do: get_by_slug(:sensors, slug)

  @doc """
  Retrieves an Agent by its slug.
  """
  @spec get_agent_by_slug(String.t()) :: component_metadata() | nil
  def get_agent_by_slug(slug), do: get_by_slug(:agents, slug)

  @doc """
  Retrieves a Slice by its slug.
  """
  @spec get_slice_by_slug(String.t()) :: component_metadata() | nil
  def get_slice_by_slug(slug), do: get_by_slug(:slices, slug)

  @doc """
  Retrieves a Demo by its slug.
  """
  @spec get_demo_by_slug(String.t()) :: component_metadata() | nil
  def get_demo_by_slug(slug), do: get_by_slug(:demos, slug)

  # Internal helpers

  defp list(type, opts) do
    case get_catalog() do
      {:ok, catalog} ->
        catalog.components
        |> Map.fetch!(type)
        |> filter_and_paginate(opts)

      {:error, _} ->
        []
    end
  end

  defp get_by_slug(type, slug) do
    case get_catalog() do
      {:ok, catalog} ->
        catalog.components
        |> Map.fetch!(type)
        |> Enum.find(&(&1.slug == slug))

      {:error, _} ->
        nil
    end
  end

  defp get_catalog do
    {:ok, :persistent_term.get(@catalog_key)}
  rescue
    ArgumentError -> {:error, :not_initialized}
  end

  defp build_catalog do
    %{
      last_updated: DateTime.utc_now(),
      components: %{
        actions: discover_spark_hosts(Jido.Action, &action_metadata/1),
        sensors: discover_spark_hosts(Jido.Sensor, &sensor_metadata/1),
        agents: discover_spark_hosts(Jido.Agent, &agent_metadata/1),
        slices: discover_spark_hosts(Jido.Slice, &slice_metadata/1),
        demos: discover_demos()
      }
    }
  end

  defp discover_spark_hosts(parent_dsl, metadata_fn) do
    loaded_applications()
    |> Enum.flat_map(&modules_for/1)
    |> Enum.filter(&(Code.ensure_loaded?(&1) and Spark.Dsl.is?(&1, parent_dsl)))
    |> Enum.map(metadata_fn)
  end

  defp discover_demos do
    loaded_applications()
    |> Enum.flat_map(&modules_for/1)
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :__jido_demo__, 0)))
    |> Enum.map(&demo_metadata/1)
  end

  defp loaded_applications do
    Application.loaded_applications()
    |> Enum.map(fn {app, _desc, _vsn} -> app end)
  end

  defp modules_for(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end

  defp action_metadata(module) do
    base_metadata(module, %{
      name: ActionInfo.name(module),
      description: ActionInfo.description(module),
      category: ActionInfo.category(module),
      tags: ActionInfo.tags(module)
    })
  end

  defp sensor_metadata(module) do
    base_metadata(module, %{
      name: SensorInfo.name(module),
      description: SensorInfo.description(module),
      schema: SensorInfo.schema(module)
    })
  end

  defp agent_metadata(module) do
    base_metadata(module, %{
      name: AgentInfo.name(module),
      description: AgentInfo.description(module),
      category: AgentInfo.category(module),
      tags: AgentInfo.tags(module),
      vsn: AgentInfo.vsn(module),
      actions: AgentInfo.actions(module),
      schema: AgentInfo.schema(module)
    })
  end

  defp slice_metadata(module) do
    base_metadata(module, %{
      name: SliceInfo.name(module),
      description: SliceInfo.description(module),
      category: SliceInfo.category(module),
      tags: SliceInfo.tags(module)
    })
  end

  defp demo_metadata(module) do
    raw = module.__jido_demo__()
    metadata_map = if Keyword.keyword?(raw), do: Map.new(raw), else: raw
    base_metadata(module, metadata_map)
  end

  defp base_metadata(module, metadata_map) do
    slug =
      module
      |> Atom.to_string()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 8)

    metadata_map
    |> Map.put(:module, module)
    |> Map.put(:slug, slug)
  end

  defp filter_and_paginate(components, opts) do
    components
    |> filter_components(opts)
    |> paginate(opts)
  end

  defp filter_components(components, opts) do
    name = Keyword.get(opts, :name)
    description = Keyword.get(opts, :description)
    category = Keyword.get(opts, :category)
    tag = Keyword.get(opts, :tag)

    Enum.filter(components, fn meta ->
      matches_name?(meta, name) and
        matches_description?(meta, description) and
        matches_category?(meta, category) and
        matches_tag?(meta, tag)
    end)
  end

  defp paginate(components, opts) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit)

    components
    |> Enum.drop(offset)
    |> maybe_limit(limit)
  end

  defp matches_name?(_meta, nil), do: true
  defp matches_name?(meta, name), do: String.contains?(meta[:name] || "", name)

  defp matches_description?(_meta, nil), do: true
  defp matches_description?(meta, desc), do: String.contains?(meta[:description] || "", desc)

  defp matches_category?(_meta, nil), do: true
  defp matches_category?(meta, category), do: meta[:category] == category

  defp matches_tag?(_meta, nil), do: true
  defp matches_tag?(meta, tag), do: is_list(meta[:tags]) and tag in meta[:tags]

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, limit) when is_integer(limit) and limit > 0, do: Enum.take(list, limit)
  defp maybe_limit(list, _), do: list
end
