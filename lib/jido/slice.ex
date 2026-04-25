defmodule Jido.Slice do
  @moduledoc """
  A Slice is a declarative bundle of agent-state schema, actions, signal
  routes, sensor subscriptions, and schedules.

  A Slice owns one flat key in `agent.state` (its `path:`). Actions belonging
  to the slice receive that slice as their second argument and return the new
  full slice value. There are no lifecycle callbacks — a Slice is fully
  described by its `use` block.

  Cross-cutting behaviour (auditing, persistence, retries, transformation)
  belongs in `Jido.Middleware`, not here. The Slice / Middleware split is the
  hard line between "what an agent does" (slices + actions) and "what
  happens around each signal" (middleware).

  ## Example

      defmodule MyApp.ChatSlice do
        use Jido.Slice,
          name: "chat",
          path: :chat,
          actions: [MyApp.Actions.SendMessage, MyApp.Actions.ListHistory],
          schema: Zoi.object(%{
            messages: Zoi.list(Zoi.any()) |> Zoi.default([]),
            model: Zoi.string() |> Zoi.default("gpt-4")
          }),
          signal_routes: [
            {"chat.send", MyApp.Actions.SendMessage},
            {"chat.history", MyApp.Actions.ListHistory}
          ]
      end

  ## Configuration Options

  - `name` - Required. Slice name (letters, numbers, underscores).
  - `path` - Required. Atom key for the slice in `agent.state`.
  - `actions` - List of action modules (default: `[]`).
  - `schema` - Optional Zoi schema for slice state.
  - `config_schema` - Optional Zoi schema for per-agent config.
  - `signal_routes` - List of signal route tuples (default: `[]`).
  - `subscriptions` - List of sensor subscription tuples (default: `[]`).
  - `schedules` - List of schedule tuples (default: `[]`).
  - `capabilities` - List of capability atoms (default: `[]`).
  - `requires` - List of dependency requirements (default: `[]`).
  - `description` - Optional description.
  - `category` - Optional category.
  - `vsn` - Optional version string.
  - `otp_app` - Optional OTP app for `Application.get_env` config resolution.
  - `tags` - List of tag strings (default: `[]`).
  - `singleton` - Whether the slice may not be aliased / duplicated (default: `false`).
  """

  alias Jido.Plugin.Manifest
  alias Jido.Plugin.Spec

  @slice_config_schema Zoi.object(
                         %{
                           name:
                             Zoi.string(
                               description:
                                 "The name of the Slice. Must contain only letters, numbers, and underscores."
                             )
                             |> Zoi.refine({__MODULE__, :validate_slice_name, []}),
                           path:
                             Zoi.atom(description: "The flat slice key in agent.state."),
                           actions:
                             Zoi.list(Zoi.atom(), description: "List of action modules.")
                             |> Zoi.refine({__MODULE__, :validate_slice_actions, []})
                             |> Zoi.default([]),
                           description:
                             Zoi.string(description: "A description of what the Slice does.")
                             |> Zoi.optional(),
                           category:
                             Zoi.string(description: "The category of the Slice.")
                             |> Zoi.optional(),
                           vsn:
                             Zoi.string(description: "Version")
                             |> Zoi.optional(),
                           otp_app:
                             Zoi.atom(
                               description:
                                 "OTP application for loading config from Application.get_env."
                             )
                             |> Zoi.optional(),
                           schema:
                             Zoi.any(description: "Zoi schema for slice state.")
                             |> Zoi.optional(),
                           config_schema:
                             Zoi.any(description: "Zoi schema for per-agent configuration.")
                             |> Zoi.optional(),
                           tags:
                             Zoi.list(Zoi.string(), description: "Tags for categorization.")
                             |> Zoi.default([]),
                           capabilities:
                             Zoi.list(Zoi.atom(),
                               description: "Capabilities provided by this slice."
                             )
                             |> Zoi.default([]),
                           requires:
                             Zoi.list(Zoi.any(),
                               description:
                                 "Requirements like {:config, :token}, {:app, :req}, {:plugin, :http}."
                             )
                             |> Zoi.default([]),
                           signal_routes:
                             Zoi.list(Zoi.any(),
                               description:
                                 "Signal route tuples like {\"post\", ActionModule} or {\"post\", {ActionModule, opts}}."
                             )
                             |> Zoi.default([]),
                           subscriptions:
                             Zoi.list(Zoi.any(),
                               description:
                                 "Sensor subscription tuples like {SensorModule, config}."
                             )
                             |> Zoi.default([]),
                           schedules:
                             Zoi.list(Zoi.any(),
                               description:
                                 "Schedule tuples like {\"*/5 * * * *\", ActionModule}."
                             )
                             |> Zoi.default([]),
                           singleton:
                             Zoi.boolean(
                               description: "If true, slice cannot be aliased or duplicated."
                             )
                             |> Zoi.default(false)
                         },
                         coerce: true
                       )

  @doc false
  @spec config_schema() :: Zoi.schema()
  def config_schema, do: @slice_config_schema

  @doc false
  @spec validate_slice_name(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_slice_name(name, _opts \\ []) do
    case Jido.Util.validate_name(name, []) do
      {:error, %{message: message}} when is_binary(message) ->
        {:error, message}

      _ ->
        :ok
    end
  end

  @doc false
  @spec validate_slice_actions([module()], keyword()) :: :ok | {:error, String.t()}
  def validate_slice_actions(actions, _opts \\ []) do
    case Jido.Util.validate_actions(actions, []) do
      {:error, %{message: message}} when is_binary(message) ->
        {:error, message}

      _ ->
        :ok
    end
  end

  defmacro __using__(opts) do
    quote location: :keep do
      alias Jido.Plugin.Manifest
      alias Jido.Plugin.Spec

      @validated_opts (case Zoi.parse(Jido.Slice.config_schema(), Enum.into(unquote(opts), %{})) do
                         {:ok, validated} ->
                           validated

                         {:error, errors} ->
                           raise CompileError,
                             description:
                               "Invalid slice configuration:\n#{Zoi.prettify_errors(errors)}"
                       end)

      @doc "Returns the slice's name."
      @spec name() :: String.t()
      def name, do: @validated_opts.name

      @doc "Returns the flat slice key in agent.state."
      @spec path() :: atom()
      def path, do: @validated_opts.path

      @doc "Returns the list of action modules provided by this slice."
      @spec actions() :: [module()]
      def actions, do: @validated_opts.actions

      @doc "Returns the slice's description."
      @spec description() :: String.t() | nil
      def description, do: @validated_opts[:description]

      @doc "Returns the slice's category."
      @spec category() :: String.t() | nil
      def category, do: @validated_opts[:category]

      @doc "Returns the slice's version."
      @spec vsn() :: String.t() | nil
      def vsn, do: @validated_opts[:vsn]

      @doc "Returns the OTP application for config resolution."
      @spec otp_app() :: atom() | nil
      def otp_app, do: @validated_opts[:otp_app]

      @doc "Returns the Zoi schema for slice state."
      @spec schema() :: Zoi.schema() | nil
      def schema, do: @validated_opts[:schema]

      @doc "Returns the Zoi schema for per-agent configuration."
      @spec config_schema() :: Zoi.schema() | nil
      def config_schema, do: @validated_opts[:config_schema]

      @doc "Returns the slice's tags."
      @spec tags() :: [String.t()]
      def tags, do: @validated_opts[:tags] || []

      @doc "Returns the capabilities provided by this slice."
      @spec capabilities() :: [atom()]
      def capabilities, do: @validated_opts[:capabilities] || []

      @doc "Returns whether this slice is a singleton."
      @spec singleton?() :: boolean()
      def singleton?, do: @validated_opts[:singleton] || false

      @doc "Returns the requirements for this slice."
      @spec requires() :: [tuple()]
      def requires, do: @validated_opts[:requires] || []

      @doc "Returns the signal routes for this slice."
      @spec signal_routes() :: [tuple()]
      def signal_routes, do: @validated_opts[:signal_routes] || []

      @doc "Returns the sensor subscriptions for this slice."
      @spec subscriptions() :: [tuple()]
      def subscriptions, do: @validated_opts[:subscriptions] || []

      @doc "Returns the schedules for this slice."
      @spec schedules() :: [tuple()]
      def schedules, do: @validated_opts[:schedules] || []

      @doc """
      Returns the slice manifest with all compile-time metadata.
      """
      @spec manifest() :: Manifest.t()
      def manifest do
        %Manifest{
          module: __MODULE__,
          name: name(),
          description: description(),
          category: category(),
          tags: tags(),
          vsn: vsn(),
          otp_app: otp_app(),
          capabilities: capabilities(),
          requires: requires(),
          path: path(),
          schema: schema(),
          config_schema: config_schema(),
          actions: actions(),
          signal_routes: signal_routes(),
          subscriptions: subscriptions(),
          schedules: schedules(),
          signal_patterns: [],
          singleton: singleton?()
        }
      end

      @doc """
      Returns the slice spec with optional per-agent configuration.
      """
      @spec plugin_spec(map()) :: Spec.t()
      def plugin_spec(config \\ %{}) do
        %Spec{
          module: __MODULE__,
          name: name(),
          path: path(),
          description: description(),
          category: category(),
          vsn: vsn(),
          schema: schema(),
          config_schema: config_schema(),
          config: config,
          signal_patterns: [],
          tags: tags(),
          actions: actions()
        }
      end

      @doc """
      Returns metadata for `Jido.Discovery` integration.
      """
      @spec __plugin_metadata__() :: map()
      def __plugin_metadata__ do
        %{
          name: name(),
          description: description(),
          category: category(),
          tags: tags()
        }
      end

      defoverridable name: 0,
                     path: 0,
                     actions: 0,
                     description: 0,
                     category: 0,
                     vsn: 0,
                     otp_app: 0,
                     schema: 0,
                     config_schema: 0,
                     tags: 0,
                     capabilities: 0,
                     singleton?: 0,
                     requires: 0,
                     signal_routes: 0,
                     subscriptions: 0,
                     schedules: 0
    end
  end
end
