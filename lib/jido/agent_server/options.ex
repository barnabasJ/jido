defmodule Jido.AgentServer.Options do
  @moduledoc """
  Options for starting an AgentServer.

  > #### Internal Module {: .warning}
  > This module is internal to the AgentServer implementation. Its API may
  > change without notice.

  Validates and normalizes startup options including agent configuration,
  hierarchy settings, middleware chain, and dispatch configuration.
  """

  alias Jido.AgentServer.ParentRef

  @type on_parent_death :: :stop | :continue | :emit_orphan

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent: Zoi.any(description: "Agent module (atom) or instantiated agent struct"),
              agent_module:
                Zoi.atom(description: "Resolved agent module (set by Options.new/1)")
                |> Zoi.optional(),
              jido:
                Zoi.atom(description: "Jido instance name for registry scoping (default: Jido)")
                |> Zoi.optional(),
              partition:
                Zoi.any(description: "Logical partition within a Jido instance")
                |> Zoi.optional(),
              id:
                Zoi.string(description: "Instance ID (auto-generated if not provided)")
                |> Zoi.optional(),
              initial_state: Zoi.map(description: "Initial agent state") |> Zoi.default(%{}),
              registry: Zoi.atom(description: "Registry module") |> Zoi.default(Jido.Registry),
              register_global:
                Zoi.boolean(description: "Register agent id in :registry during init")
                |> Zoi.default(true),
              default_dispatch:
                Zoi.any(description: "Default dispatch config for Emit directives")
                |> Zoi.optional(),
              middleware:
                Zoi.list(Zoi.any(),
                  description:
                    "Runtime-appended middleware modules. Each entry is a bare module or {Mod, opts_map}."
                )
                |> Zoi.default([]),
              parent: Zoi.any(description: "Parent reference for hierarchy") |> Zoi.optional(),
              on_parent_death:
                Zoi.atom(description: "Behavior when parent dies")
                |> Zoi.default(:stop),
              spawn_fun:
                Zoi.any(description: "Custom function for spawning children") |> Zoi.optional(),
              skip_schedules:
                Zoi.boolean(description: "Skip registering plugin schedules (useful for tests)")
                |> Zoi.default(false),

              # InstanceManager integration (set by Jido.Agent.InstanceManager)
              lifecycle_mod:
                Zoi.atom(description: "Lifecycle module implementing Jido.AgentServer.Lifecycle")
                |> Zoi.default(Jido.AgentServer.Lifecycle.Noop),
              pool:
                Zoi.atom(description: "Manager name if started via Jido.Agent.InstanceManager")
                |> Zoi.optional(),
              pool_key:
                Zoi.any(description: "Manager key if started via Jido.Agent.InstanceManager")
                |> Zoi.optional(),
              idle_timeout:
                Zoi.any(
                  description: "Idle timeout in ms before hibernate/stop (:infinity to disable)"
                )
                |> Zoi.default(:infinity),
              storage:
                Zoi.any(description: "Storage config (nil | Module | {Module, opts})")
                |> Zoi.optional(),
              restored_from_storage:
                Zoi.boolean(description: "Whether the startup agent was already thawed")
                |> Zoi.default(false),

              # Debug mode
              debug:
                Zoi.boolean(description: "Enable debug mode with event buffer")
                |> Zoi.default(false)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Creates validated Options from a keyword list or map.

  Normalizes and validates all options, including:
  - Generating an ID if not provided
  - Validating the agent module/struct
  - Resolving `:agent_module` from the `:agent` option when not given explicitly
  - Parsing parent reference

  Returns `{:ok, options}` or `{:error, reason}`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    opts |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, _} <- validate_agent(attrs[:agent]),
         {:ok, agent_module} <- resolve_agent_module(attrs),
         {:ok, parent} <- validate_parent(attrs[:parent]) do
      attrs =
        attrs
        |> Map.put(:agent_module, agent_module)
        |> Map.put(:parent, parent)

      Zoi.parse(@schema, attrs)
    end
  end

  def new(_), do: {:error, Jido.Error.validation_error("Options requires a keyword list or map")}

  @doc """
  Creates validated Options from a keyword list or map, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, options} -> options
      {:error, reason} -> raise Jido.Error.validation_error("Invalid Options", details: reason)
    end
  end

  # Normalize attributes with defaults
  defp normalize_attrs(attrs) do
    id =
      case Map.get(attrs, :id) do
        nil -> extract_agent_id(attrs[:agent]) || Jido.Util.generate_id()
        "" -> extract_agent_id(attrs[:agent]) || Jido.Util.generate_id()
        id when is_binary(id) -> id
        id when is_atom(id) -> Atom.to_string(id)
      end

    partition = Map.get(attrs, :partition)

    jido_instance = Map.get(attrs, :jido, Jido)
    registry = Map.get(attrs, :registry, Jido.registry_name(jido_instance))
    attrs = Map.put(attrs, :jido, jido_instance)

    attrs
    |> Map.put(:id, id)
    |> Map.put(:partition, partition)
    |> Map.put(:registry, registry)
  end

  defp extract_agent_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp extract_agent_id(_), do: nil

  defp validate_agent(nil), do: {:error, Jido.Error.validation_error("agent is required")}

  defp validate_agent(agent) when is_atom(agent) do
    case Code.ensure_loaded(agent) do
      {:module, _} ->
        if function_exported?(agent, :new, 0) or function_exported?(agent, :new, 1) or
             function_exported?(agent, :new, 2) do
          {:ok, agent}
        else
          {:error,
           Jido.Error.validation_error("agent module must implement new/0, new/1, or new/2")}
        end

      {:error, _} ->
        {:error, Jido.Error.validation_error("agent module not found: #{inspect(agent)}")}
    end
  end

  defp validate_agent(%{__struct__: _} = agent), do: {:ok, agent}

  defp validate_agent(_),
    do: {:error, Jido.Error.validation_error("agent must be a module or struct")}

  defp resolve_agent_module(attrs) do
    case Map.get(attrs, :agent_module) do
      mod when is_atom(mod) and not is_nil(mod) ->
        {:ok, mod}

      _ ->
        case attrs[:agent] do
          mod when is_atom(mod) and not is_nil(mod) ->
            {:ok, mod}

          %{agent_module: mod} when is_atom(mod) and not is_nil(mod) ->
            {:ok, mod}

          %{__struct__: struct_mod} ->
            {:ok, struct_mod}

          _ ->
            {:error,
             Jido.Error.validation_error(
               "agent_module is required (provide :agent as a module or set :agent_module)"
             )}
        end
    end
  end

  defp validate_parent(nil), do: {:ok, nil}

  defp validate_parent(%ParentRef{} = parent), do: {:ok, parent}

  defp validate_parent(attrs) when is_map(attrs) do
    ParentRef.new(attrs)
  end

  defp validate_parent(_) do
    {:error, Jido.Error.validation_error("parent must be nil or a ParentRef")}
  end
end
