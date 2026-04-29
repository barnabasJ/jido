# 0024. Runtime schema language consolidation — open

- Status: Proposed
- Implementation: Pending — **decision not yet made**
- Date: 2026-04-29
- Related ADRs: [0023](0023-spark-dsl-and-registerable-extensions.md) (Spark DSL migration; this ADR is the runtime-validation half).
- Related commits / PRs: —

## Context

The codebase carries three runtime schema languages plus one
compile-time DSL parser. Surfacing this is the first step toward
deciding whether the polyglot is intentional or accidental complexity.

### What's actually in tree

- **`zoi ~> 0.17`** is a direct dep ([mix.exs](../../mix.exs)). Zod-shaped
  validator, struct generator, type-spec generator, with coercion /
  refinements / transforms. Used for:
  - Defining structs: `defstruct Zoi.Struct.struct_fields(@schema)` +
    `@type t :: unquote(Zoi.type_spec(@schema))` is the canonical
    pattern across [agent.ex:196–197](../../lib/jido/agent.ex),
    [memory.ex:40–41](../../lib/jido/memory.ex),
    [identity.ex](../../lib/jido/identity.ex), [thread.ex](../../lib/jido/thread.ex),
    [plugin/manifest.ex](../../lib/jido/plugin/manifest.ex), and others.
    Public API: [`Zoi.Struct.struct_fields/1`](../../deps/zoi/lib/zoi/struct.ex#L67),
    [`Zoi.Struct.enforce_keys/1`](../../deps/zoi/lib/zoi/struct.ex#L45).
  - Validating runtime data — agent state, slice state, sometimes
    action input.
- **`nimble_options ~> 1.1`** is a direct dep ([mix.exs](../../mix.exs)),
  also pulled transitively by `req_llm` and `jido_signal`. A tiny
  keyword-list validator. Used for:
  - Action input validation when an action's `schema:` is in
    keyword-list form: `NimbleOptions.validate(data_kw, schema)` at
    [action/schema.ex:216](../../lib/jido/action/schema.ex).
  - "Custom validator" callbacks: [`Jido.Util.validate_name/2`](../../lib/jido/util.ex#L103)
    is documented as "used as a custom validator for NimbleOptions."
  - Error formatting: [action/error.ex:452–495](../../lib/jido/action/error.ex)
    pattern-matches on `%NimbleOptions.ValidationError{}`.
- **`Spark.Options`** is shipped *inside* the `:spark` dep — a vendored
  fork of NimbleOptions. Spark's moduledoc states the lineage
  explicitly ([deps/spark/lib/spark/options/options.ex:113–132](../../deps/spark/lib/spark/options/options.ex)):

  > *"This module began its life as a vendored form of `NimbleOptions`,
  > meaning that we copied it from `NimbleOptions` into `Spark`. We had
  > various features to add to it, and the spirit of nimble options is
  > to be as lightweight as possible. With that in mind, we were advised
  > to vendor it."*

  Compile-time DSL options are validated through `Spark.Options.validate/2`
  ([deps/spark/lib/spark/dsl/extension.ex:1015](../../deps/spark/lib/spark/dsl/extension.ex)).
  Spark.Options has extra types and a compile-time validator
  (`Spark.Options.Validator`) that vanilla NimbleOptions doesn't.
- **JSON Schema maps** are accepted as a third runtime format by
  [`Jido.Action.Schema`](../../lib/jido/action/schema.ex). The dispatch
  function `schema_type/1` returns `:nimble | :zoi | :json_schema |
  :empty | :unknown`; `validate/2` routes by tag. JSON Schema is
  pass-through (no runtime validation; the schema is purely for LLM
  tool export).

### How the layers actually interact

- **DSL parsing (compile-time):** `Spark.Options` validates section
  schemas. Authors write keyword-list shapes; Spark expands them into
  a `dsl_state` map and emits accessor functions.
- **Runtime data validation:** `Jido.Action.Schema.validate/2` is the
  shared adapter for action input/output. It accepts NimbleOptions
  shape, Zoi shape, OR JSON Schema map. The caller doesn't need to
  know which.
- **Struct generation:** Zoi-only. `defstruct` over
  `Zoi.Struct.struct_fields(@schema)` is how every Jido data
  module is declared.

### What's wrong (or might be wrong)

The polyglot was acquired incrementally:

- Action schemas predate Zoi adoption — they were authored as
  NimbleOptions keyword lists when that was the only schema shape in
  Elixir.
- Zoi was adopted later for struct generation + Zod-like ergonomics,
  and crept into agent/slice state schemas where its expressiveness
  helps.
- Spark arrived in [ADR 0023](0023-spark-dsl-and-registerable-extensions.md)
  and brought `Spark.Options` along for the DSL parser.

The asymmetry users notice:

```elixir
# Slice — Zoi
slice do
  schema Zoi.object(%{counter: Zoi.integer() |> Zoi.default(0)})
end

# Action input — NimbleOptions keyword list
action do
  schema days: [type: :integer, default: 0],
         years: [type: :integer, default: 0]
end
```

Two languages, written next to each other, often in the same file.
The inconsistency is real — but it's a developer-experience issue,
not a correctness issue. Each schema type works fine for what it
validates.

## Decision

**Not yet decided.** This ADR captures the situation in tree and
enumerates the candidate moves so the team can pick deliberately.

### Candidate (a) — status quo, accurately documented

Three runtime schema languages (NimbleOptions, Zoi, JSON Schema) +
one compile-time DSL parser (Spark.Options). Two real top-level
deps (`zoi`, `nimble_options`) plus what `:spark` drags in.

Document the boundary explicitly:
- Compile-time DSL options use `Spark.Options` (handled by Spark).
- Runtime data validation accepts whichever shape the schema is
  declared in; `Jido.Action.Schema` dispatches.
- Struct generation is Zoi-only.

Cost: documentation only. No code changes.

### Candidate (b) — drop NimbleOptions as an action-schema shape

Rewrite every action whose `schema:` is a NimbleOptions keyword
list into Zoi. `Jido.Action.Schema` keeps Zoi + JSON Schema only;
the `:nimble` branch deletes. Vanilla `nimble_options` drops from
the direct-deps list ([mix.exs](../../mix.exs)) — it stays as a
transitive dep through `req_llm` / `jido_signal` but disappears from
`lib/jido/`.

Cost (estimate before survey): every action module in tree gets a
Zoi rewrite of its schema. The `validate_nimble/2` branch + the
`%NimbleOptions.ValidationError{}` formatters in
`Jido.Action.Error` delete. Action-input docs in user guides
rewrite. Out-of-tree action authors have to migrate. ADR 0023's
"NimbleOptions for compile-time, Zoi for runtime" framing was
already inaccurate; this brings the runtime story in line with the
*Zoi for runtime* half cleanly. Spark.Options stays at the DSL
boundary.

Action count to migrate: TBD — count before deciding.

### Candidate (c) — collapse Spark.Options into NimbleOptions or Zoi

Not possible without forking Spark. Spark's parser, transformers,
verifiers, and cheat-sheet generator all assume `Spark.Options`.
Removing `Spark.Options` means removing Spark; that decision was
made the other way in ADR 0023. Off the table.

### Candidate (d) — drop Zoi, replace with NimbleOptions / Spark.Options

Possible only if we replace Zoi's struct generator (`Zoi.Struct.struct_fields/1`)
and type-spec generator (`Zoi.type_spec/1`) with hand-rolled `defstruct`
+ hand-written `@type t`. NimbleOptions / Spark.Options has no struct
generator. The cost is rewriting every Jido data module's struct
declaration by hand and losing Zoi's coercion / refinements / transforms
on runtime data. Not worth it for the consistency win — Zoi is the
only option in the Elixir ecosystem that combines validation,
structs, and type specs in one package. Off the table unless a
concrete reason to drop it surfaces.

## Consequences (if (b) is chosen)

- One runtime schema language in tree (Zoi, plus JSON Schema as a
  passthrough export). Cleaner mental model: "you write Zoi, you
  read Zoi."
- Vanilla `:nimble_options` leaves `mix.exs` as a top-level dep.
  Stays as a transitive through `req_llm` / `jido_signal`, but
  doesn't appear in `lib/jido/`.
- `Spark.Options` stays at the DSL boundary because Spark requires
  it. Users writing a `Spark.Dsl.Section`'s schema still write
  keyword-list shape — that's compile-time, separate from the
  runtime story.
- `Jido.Action.Schema` shrinks: `:nimble` branch deletes;
  `schema_type/1` returns `:zoi | :json_schema | :empty | :unknown`.
  Error formatting in `Jido.Action.Error` loses
  `%NimbleOptions.ValidationError{}` matchers.
- Hard cut for action authors. Per the framework's NO LEGACY
  ADAPTERS rule ([guides/tasks/README.md](../tasks/README.md)),
  no shim that accepts both shapes.

## Consequences (if (a) is chosen)

- Three runtime schema languages stay. Action authors continue to
  pick NimbleOptions for trivial inputs (`schema name: [type:
  :string]`) and Zoi for richer ones (`schema Zoi.object(%{...})`).
- The "why two" question keeps surfacing in onboarding.
- ADR 0023 §6's "NimbleOptions vs Zoi" partition gets corrected to
  reflect the actual tri-format runtime + Spark.Options compile-time
  layout.
- No code churn.

## Alternatives considered

- **Status quo with no documentation refresh.** Worse than (a) —
  same code with the existing imprecise framing in ADR 0023.
  Rejected; if we keep the polyglot, document it accurately.
- **Make `:nimble_options` an explicit transitive-only dep** (drop
  the line from `mix.exs` but keep using `NimbleOptions.validate/2`
  through the transitive). Brittle — a future `req_llm` / `jido_signal`
  release could drop the dep and break us. If we keep
  NimbleOptions, keep it as a direct dep.
- **Migrate to a new schema library (e.g. `:nestru`, `:peri`).**
  Doesn't help — we'd still have Spark.Options at the DSL boundary
  and would need a runtime validator. Adding a fourth language
  rather than reducing.

## Open questions

1. **How many action modules in tree have NimbleOptions-shaped
   schemas?** Count via `git grep -lE '^\s*schema [a-z_]+: \[' lib/`.
   Rough order-of-magnitude tells us the cost of (b).
2. **Are out-of-tree consumers writing NimbleOptions or Zoi action
   schemas more often?** Anecdotal; check the `usage-rules.md` and
   guides for which shape is the documented default.
3. **Does keeping vanilla NimbleOptions buy us anything beyond
   action-schema shape?** `Jido.Util.validate_name/2` is described
   as a custom NimbleOptions validator, but the same function also
   works as a custom validator for `Spark.Options` (the API is
   compatible — `Spark.Options` was forked from NimbleOptions and
   the `{:custom, M, F, A}` shape is identical). So there's no
   technical lock-in beyond the action-schema dispatcher.

When these are answered, this ADR can flip to Accepted with a
specific candidate and a task to implement it.
