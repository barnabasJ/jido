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
              agent_module:
                Zoi.atom(description: "Agent module; required. Always constructed via new/1."),
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
  - Validating the agent module
  - Parsing parent reference

  Returns `{:ok, options}` or `{:error, reason}`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    opts |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, agent_module} <- validate_agent_module(attrs[:agent_module]),
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
        nil -> Jido.Util.generate_id()
        "" -> Jido.Util.generate_id()
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

  defp validate_agent_module(nil),
    do: {:error, Jido.Error.validation_error("agent_module is required")}

  defp validate_agent_module(mod) when is_atom(mod) do
    case Code.ensure_loaded(mod) do
      {:module, _} ->
        if function_exported?(mod, :new, 0) or function_exported?(mod, :new, 1) do
          {:ok, mod}
        else
          {:error, Jido.Error.validation_error("agent_module must implement new/0 or new/1")}
        end

      {:error, _} ->
        {:error, Jido.Error.validation_error("agent_module not found: #{inspect(mod)}")}
    end
  end

  defp validate_agent_module(_),
    do: {:error, Jido.Error.validation_error("agent_module must be a module atom")}

  defp validate_parent(nil), do: {:ok, nil}

  defp validate_parent(%ParentRef{} = parent), do: {:ok, parent}

  defp validate_parent(attrs) when is_map(attrs) do
    ParentRef.new(attrs)
  end

  defp validate_parent(_) do
    {:error, Jido.Error.validation_error("parent must be nil or a ParentRef")}
  end
end
