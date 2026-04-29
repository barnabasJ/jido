defmodule Jido.Dsl.Agent do
  @moduledoc """
  Spark DSL extension for `Jido.Agent`.

  Defines three host-owned sections:

    * `agent do … end` — agent identity (name, description, path, schema)
    * `signal_routes do … end` — `route` entries
    * `schedules do … end` — `schedule` entries

  The `extensions: […]` keyword on `use Jido.Agent` is the single
  ordered registration list per ADR 0023 §3. The `WalkExtensions`
  transformer classifies each entry by marker (`__jido_plugin__/0` /
  `__jido_slice__/0` / `Jido.Middleware` behaviour) and produces
  the same internal `slices` / `plugins` / `middleware` lists today's
  macro builds.

  Per-extension typed sections (e.g. `memory do … end`, `slack do … end`)
  arrive in task 0035 once `use Jido.Slice` / `use Jido.Plugin` /
  `use Jido.Middleware` themselves register Spark sections. For task
  0034 only, extension config is carried as a plain map on the
  registration entry: `{Module, %{key: val}}`.
  """

  alias Jido.Dsl.Agent.Route
  alias Jido.Dsl.Agent.Schedule

  @agent_section %Spark.Dsl.Section{
    name: :agent,
    describe: "Agent identity and base configuration.",
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Agent name (letters, numbers, underscores)."
      ],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string],
      path: [
        type: :atom,
        required: true,
        doc: "Atom slice key where the agent's user-domain state lives."
      ],
      schema: [
        type: :any,
        default: [],
        doc: "Zoi or NimbleOptions schema for the agent's slice state."
      ]
    ]
  }

  @route %Spark.Dsl.Entity{
    name: :route,
    describe: "Maps a signal type/pattern to an action target.",
    target: Route,
    args: [:type, :action],
    schema: [
      type: [type: :string, required: true],
      action: [type: {:or, [:atom, :mfa]}, required: true],
      priority: [type: :integer, default: 0],
      match: [type: {:fun, 1}],
      static: [type: :map]
    ]
  }

  @signal_routes_section %Spark.Dsl.Section{
    name: :signal_routes,
    describe: "Compile-time signal route table.",
    entities: [@route]
  }

  @schedule %Spark.Dsl.Entity{
    name: :schedule,
    describe: "Declarative cron schedule.",
    target: Schedule,
    args: [:cron, :signal_type],
    schema: [
      cron: [type: :string, required: true],
      signal_type: [type: :string, required: true],
      data: [type: :map, default: %{}],
      job_id: [type: :any],
      timezone: [type: :string]
    ]
  }

  @schedules_section %Spark.Dsl.Section{
    name: :schedules,
    describe: "Declarative agent-level cron schedules.",
    entities: [@schedule]
  }

  use Spark.Dsl.Extension,
    sections: [
      @agent_section,
      @signal_routes_section,
      @schedules_section
    ],
    transformers: [
      Jido.Dsl.Agent.Transformers.WalkExtensions,
      Jido.Dsl.Agent.Transformers.MergeSchemas,
      Jido.Dsl.Agent.Transformers.ExpandRoutes,
      Jido.Dsl.Agent.Transformers.ValidateRequirements,
      Jido.Dsl.Agent.Transformers.GenerateAccessors
    ],
    verifiers: [
      Jido.Dsl.Agent.Verifiers.UniquePaths,
      Jido.Dsl.Agent.Verifiers.NoSingletonAlias,
      Jido.Dsl.Agent.Verifiers.NoRouteConflicts,
      Jido.Dsl.Agent.Verifiers.NoSectionNameCollisions
    ]
end
