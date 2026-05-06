defmodule Jido.Dsl.Agent do
  @moduledoc """
  Spark DSL extension for `Jido.Agent`.

  Defines four host-owned sections:

    * `agent do … end` — agent identity (name, description, path, schema)
    * `slices do … end` — slice/plugin mounts at agent-declared paths
    * `signal_routes do … end` — `route` entries
    * `schedules do … end` — `schedule` entries

  The `slices do … end` section is the single source of truth for
  path-to-slice binding on the agent. Each `slice :path, Module` line
  mounts a slice (or plugin) at the agent-declared `:path`. Slice and
  plugin modules no longer declare `path` on themselves — the agent
  owns the binding so the same slice module can mount at different
  paths on different agents.

  Middleware lives at the top level on `use Jido.Agent, middleware: […]`
  because order matters and a flat ordered list is the right shape.
  Plugin modules with middleware behaviour appear in **both** places:
  in `slices do …` for path/options, and in `middleware: […]` for
  ordering.

  The `extensions: […]` keyword on `use Jido.Agent` is reserved for
  modules that contribute a typed DSL section to the host agent (the
  `Jido.Slice.Extension` host-section mechanism, e.g. `react do … end`
  for `Jido.Slices.AiReact`). It is **not** the channel for slice/plugin
  enumeration anymore.
  """

  alias Jido.Dsl.Agent.Route
  alias Jido.Dsl.Agent.Schedule
  alias Jido.Dsl.Agent.SliceMount

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
        doc:
          "Atom slice key where the agent's user-domain state lives. " <>
            "Required when `schema:` is set; omit both for a pure composition agent."
      ],
      schema: [
        type: :any,
        default: [],
        doc:
          "Zoi or NimbleOptions schema for the agent's slice state. " <>
            "Required when `path:` is set; omit both for a pure composition agent."
      ]
    ]
  }

  @slice_mount %Spark.Dsl.Entity{
    name: :slice,
    describe: "Mounts a slice or plugin at an agent-declared path.",
    target: SliceMount,
    args: [:path, :module],
    schema: [
      path: [
        type: :atom,
        required: true,
        doc: "Atom slice key in agent.state where this slice's value lives."
      ],
      module: [
        type: :atom,
        required: true,
        doc: "Slice (`use Jido.Slice`) module to mount."
      ],
      options: [
        type: {:or, [:keyword_list, :map]},
        default: [],
        doc:
          "Configuration map / keyword list to seed the slice with. Merged " <>
            "with values from any contributed-section block (e.g. `react do … end`)."
      ]
    ]
  }

  @slices_section %Spark.Dsl.Section{
    name: :slices,
    describe:
      "Slice and plugin mounts. Each `slice :path, Module` registers a slice/plugin " <>
        "at the agent-declared path. The same module may be mounted at multiple " <>
        "paths (`slice :slack_support, SlackPlugin; slice :slack_sales, SlackPlugin`); " <>
        "at signal-route dispatch the framework fans the action out, calling it once " <>
        "per matching mount with each mount's own slice state and `ctx.slice_config` " <>
        "(per-mount config visible to the action).",
    entities: [@slice_mount]
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
      @slices_section,
      @signal_routes_section,
      @schedules_section
    ],
    transformers: [
      Jido.Dsl.Agent.Transformers.WalkExtensions,
      Jido.Dsl.Agent.Transformers.MergeSchemas,
      Jido.Dsl.Agent.Transformers.ExpandRoutes,
      Jido.Dsl.Agent.Transformers.GenerateAccessors
    ],
    verifiers: [
      Jido.Dsl.Agent.Verifiers.PathSchemaPair,
      Jido.Dsl.Agent.Verifiers.UniquePaths
    ]
end
