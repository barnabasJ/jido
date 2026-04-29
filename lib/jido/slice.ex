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
        use Jido.Slice

        slice do
          name "chat"
          path :chat
          schema Zoi.object(%{
            messages: Zoi.list(Zoi.any()) |> Zoi.default([]),
            model: Zoi.string() |> Zoi.default("gpt-4")
          })
        end

        actions do
          action MyApp.Actions.SendMessage
          action MyApp.Actions.ListHistory
        end

        signal_routes do
          route "chat.send", MyApp.Actions.SendMessage
          route "chat.history", MyApp.Actions.ListHistory
        end
      end

  ## Sections

  - `slice do … end` — slice identity (`name`, `path`, `description`,
    `category`, `vsn`, `otp_app`, `schema`, `config_schema`, `tags`,
    `singleton`).
  - `actions do … end` — `action ModuleAction` entries.
  - `signal_routes do … end` — `route "type", Action, opts` entries.
  - `subscriptions do … end` — `subscription Sensor, %{config}` entries.
  - `schedules do … end` — `schedule "cron", Action, %{data}` entries.
  - `capabilities do … end` — `capability :name` entries.
  - `requires do … end` — `requires :kind, :name` entries.
  """

  use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Slice]]

  @doc false
  @spec validate_slice_name(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_slice_name(name, _opts \\ []) do
    case Jido.Util.validate_name(name, []) do
      {:error, %{message: message}} when is_binary(message) ->
        {:error, message}

      _ ->
        {:ok, name}
    end
  end

  @doc false
  @spec validate_slice_actions([module()], keyword()) ::
          {:ok, [module()]} | {:error, String.t()}
  def validate_slice_actions(actions, _opts \\ []) do
    case Jido.Util.validate_actions(actions, []) do
      {:error, %{message: message}} when is_binary(message) ->
        {:error, message}

      _ ->
        {:ok, actions}
    end
  end

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      @doc false
      @spec __jido_slice__() :: true
      def __jido_slice__, do: true
    end
  end
end
