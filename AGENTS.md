# AGENTS.md - Jido Guide

## Intent
Build reliable agent systems by separating pure decision logic from runtime side-effect execution.

## The Bright Line
- **Actions mutate state.** The action's return value is the **sole channel** for `agent.state` (domain) writes.
- **Directives are pure I/O.** They emit signals, spawn processes, schedule messages — and **mutate no state**: not domain (`agent.state`), not runtime (`%AgentServer.State{}`), nothing. Their results, if any, come back as signals that re-enter the pipeline.
- **Type-system enforced.** `Jido.AgentServer.DirectiveExec.exec/3` returns `:ok | {:stop, term()}` — there is no state slot in the return shape, so a directive author cannot accidentally write one.

Sole exception: middleware may stage `ctx.agent` for I/O purposes ([ADR 0018](guides/adr/0018-tagged-tuple-return-shape.md) §1). Canonical rule: [ADR 0019](guides/adr/0019-actions-mutate-state-directives-do-side-effects.md).

## Runtime Baseline
- Elixir `~> 1.18`
- OTP `27+` (release QA baseline)

## Commands
- `mix test` (default alias excludes `:flaky`)
- `mix test --include flaky` (full suite)
- `mix test --cover` (coverage gate)
- `mix q` or `mix quality` (`format --check-formatted`, `compile --warnings-as-errors`, `credo`, `dialyzer`)
- `mix docs` (local docs)

## Architecture Snapshot
- `Jido.Agent`: pure agent module with immutable state and `cmd/2`
- `Jido.AgentServer`: GenServer runtime for directives, lifecycle, and message flow
- `Jido.Agent.Directive.*`: typed pure-I/O descriptors (`Emit`, `SpawnAgent`, `StopChild`, etc.)
- Plugins/sensors provide capability composition without coupling core agent logic

## Standards
- Keep `cmd/2` pure: same input => same `{agent, directives}` output
- Directives mutate **no** state — neither `agent.state` (domain) nor `%AgentServer.State{}` (runtime). State changes flow through the action's return value; runtime bookkeeping flows through GenServer callbacks and `process_signal/2` cascade callbacks
- Use **Zoi-first** schemas for new agent/plugin/signal contracts
- Preserve tagged tuple and structured error contracts at public boundaries
- Keep cross-agent communication on signals/directives, not ad-hoc process messages

## Testing and QA
- Prefer pure agent tests first, then AgentServer/runtime integration tests
- Use helpers from `test/AGENTS.md` (`JidoTest.Case`, `JidoTest.Eventually`) for async assertions
- Avoid `Process.sleep/1` in tests; assert eventual state/event behavior

## Release Hygiene
- Keep semver ranges stable (`~> 2.0` for Jido ecosystem peers)
- Use Conventional Commits
- Update `CHANGELOG.md`, guides, and examples for behavior/API changes

## References
- `README.md`
- `usage-rules.md`
- `guides/`
- `test/AGENTS.md`
- https://hexdocs.pm/jido
