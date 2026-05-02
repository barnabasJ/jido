defmodule Jido.Directives.SpawnManagedAgent do
  @moduledoc """
  Spawn an agent via `Jido.Agent.InstanceManager`.

  Unlike `SpawnAgent` which creates a child in the parent's DynamicSupervisor,
  this starts the agent through InstanceManager.

  ## Fields

  - `namespace` - InstanceManager namespace (e.g. `:threads`, `:sessions`)
  - `key` - Registration key (any term InstanceManager can index by)
  - `tag` - Tag for the `jido.agent.child.started` signal back to parent
  - `initial_state` - Initial state for the agent
  - `parent` - Optional explicit parent ref. When nil the executor uses
    `self()` + the current agent's id as the parent. Set this when the
    directive is being evaluated outside the intended parent's process
    (e.g. pod runtime orchestrating an adoption on behalf of the pod).
  - `agent_opts` - Extra options passed to AgentServer

  ## Executing directly

  `execute/2` performs the spawn synchronously and returns the new child
  pid, so callers outside the directive pipeline can reuse the exact
  same shape. The `DirectiveExec` impl is a thin wrapper that discards
  the pid to match the protocol contract.

  ## Examples

      %SpawnManagedAgent{
        namespace: :threads,
        key: "thread-123",
        tag: :worker,
        initial_state: %{thread_id: "thread-123"}
      }

      {:ok, pid} = SpawnManagedAgent.execute(directive, state)
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              namespace: Zoi.atom(description: "InstanceManager namespace"),
              key: Zoi.any(description: "Registration key (any term)"),
              tag: Zoi.any(description: "Tag for child.started signal"),
              initial_state:
                Zoi.map(description: "Initial state for the agent") |> Zoi.default(%{}),
              parent:
                Zoi.any(description: "Explicit %ParentRef{} (or compatible map) for the child.")
                |> Zoi.optional(),
              agent_opts:
                Zoi.list(Zoi.any(), description: "Extra AgentServer options") |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for SpawnManagedAgent."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Executes the directive synchronously, returning `{:ok, pid}` for the
  spawned child or `{:error, reason}` on failure.

  Resolves the parent ref in priority order:
  1. `directive.parent` if supplied.
  2. `parent:` entry already present in `directive.agent_opts`.
  3. A default ref built from `self()` + `state.id` + `directive.tag`.

  Whichever wins is threaded into `agent_opts` so the child AgentServer
  attaches it to `state.parent` at init, which in turn causes
  `handle_continue(:post_init, ...)` to emit `jido.agent.child.started`.
  """
  @spec execute(t(), %{required(:id) => String.t(), optional(any()) => any()} | nil) ::
          {:ok, pid()} | {:error, term()}
  def execute(%__MODULE__{} = directive, state \\ nil) do
    parent_ref = resolve_parent(directive, state)

    agent_opts =
      if parent_ref do
        Keyword.put_new(directive.agent_opts, :parent, parent_ref)
      else
        directive.agent_opts
      end

    get_opts = [
      initial_state: directive.initial_state,
      agent_opts: agent_opts
    ]

    get_opts =
      case Keyword.get(agent_opts, :partition) do
        nil -> get_opts
        partition -> Keyword.put(get_opts, :partition, partition)
      end

    Jido.Agent.InstanceManager.get(directive.namespace, directive.key, get_opts)
  end

  # Priority: explicit directive.parent > agent_opts[:parent] > self-as-parent
  # fallback built from `state`. The fallback is only valid when execute/2 is
  # called from the intended parent's own process (i.e. `self()` is the
  # parent agent), which is true for DirectiveExec callers.
  defp resolve_parent(%__MODULE__{parent: parent}, _state) when not is_nil(parent), do: parent

  defp resolve_parent(%__MODULE__{agent_opts: agent_opts} = directive, state) do
    case Keyword.get(agent_opts, :parent) do
      nil -> default_parent_ref(directive, state)
      ref -> ref
    end
  end

  defp default_parent_ref(%__MODULE__{tag: tag}, %{id: id}) when is_binary(id) do
    %{pid: self(), id: id, tag: tag, meta: %{}}
  end

  defp default_parent_ref(_directive, _state), do: nil
end
