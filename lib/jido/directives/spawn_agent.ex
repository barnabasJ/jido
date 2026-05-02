defmodule Jido.Directives.SpawnAgent do
  @moduledoc """
  Spawn a child agent with parent-child hierarchy tracking.

  Unlike `Spawn`, this directive specifically spawns another Jido agent
  and sets up the logical parent-child relationship:

  - Child's parent reference points to the spawning agent
  - Parent monitors the child process
  - Parent tracks child in its children map by tag
  - Child exit signals are delivered to parent as `jido.agent.child.exit`
  - Child sees `ctx.parent` (a `%ParentRef{}`) on every signal while attached

  The logical relationship is independent from OTP supervisory ancestry. If
  the child later becomes orphaned, `ctx.parent` becomes `nil` and the child
  must be explicitly reattached with `AdoptChild`. The active logical
  binding is mirrored into `Jido.RuntimeStore`, so child restarts continue
  to use the current parent relationship instead of stale startup metadata.

  ## Fields

  - `agent` - Agent module (atom) or pre-built agent struct to spawn
  - `tag` - Tag for tracking this child (used as key in children map)
  - `opts` - Additional options passed to child AgentServer. Supports standard
    child startup options like `:id`, `:initial_state`, and `:on_parent_death`,
    but not InstanceManager lifecycle options like `:idle_timeout`,
    `:lifecycle_mod`, `:pool`, or `:pool_key`
  - `meta` - Metadata to pass to child via parent reference
  - `restart` - Restart policy for the child under supervision (default: `:transient`)

  ## Examples

      # Spawn a worker agent
      %SpawnAgent{agent: MyWorkerAgent, tag: :worker_1}

      # Spawn with custom ID and initial state
      %SpawnAgent{
        agent: MyWorkerAgent,
        tag: :processor,
        opts: %{id: "custom-id", initial_state: %{batch_size: 100}}
      }

      # Spawn with metadata for the child
      %SpawnAgent{
        agent: MyWorkerAgent,
        tag: :handler,
        meta: %{assigned_topic: "events.user"}
      }

      # Override restart behavior for long-lived workers
      %SpawnAgent{
        agent: MyWorkerAgent,
        tag: :supervised,
        restart: :permanent
      }
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent: Zoi.any(description: "Agent module (atom) or pre-built agent struct"),
              tag: Zoi.any(description: "Tag for tracking this child"),
              opts: Zoi.map(description: "Options for child AgentServer") |> Zoi.default(%{}),
              meta: Zoi.map(description: "Metadata to pass to child") |> Zoi.default(%{}),
              restart:
                Zoi.atom(description: "Restart policy for the child")
                |> Zoi.refine({Jido.Directives, :validate_restart_policy, []})
                |> Zoi.default(:transient)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for SpawnAgent."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
