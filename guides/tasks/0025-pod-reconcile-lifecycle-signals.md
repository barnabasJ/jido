---
name: Task 0025 — Pod reconcile lifecycle signals: restore or supersede
description: ADR 0004 says Pod.Runtime.reconcile/2 emits jido.pod.reconcile.started/.completed/.failed. Code does not. Either restore the emissions or supersede ADR 0004 because the post-ADR-0017 mutation state machine subsumes its observability promise.
---

# Task 0025 — Pod reconcile lifecycle signals: restore or supersede

- Implements: re-aligns code with [ADR 0004](../adr/0004-pod-lifecycle-signals.md), or formally retires it.
- Depends on: nothing.
- Blocks: nothing.
- Leaves tree: green.

## Context

[ADR 0004](../adr/0004-pod-lifecycle-signals.md) is `Status: Accepted, Implementation: Complete (commit e624111)`. Its Decision section stipulates three signals from `Pod.Runtime.reconcile/2`:

- `jido.pod.reconcile.started` — before waves execute, data `%{requested: [name, ...]}`
- `jido.pod.reconcile.completed` — on success, data `%{requested: ..., started: ..., failed: ...}`
- `jido.pod.reconcile.failed` — on error, data `%{requested: ..., error: term}`

`grep "jido.pod.reconcile" lib/` returns zero hits. `lib/jido/pod/runtime.ex:95-107` is now a thin wrapper over `Mutable.mutate_and_wait/3` and never casts these signals. The signals were almost certainly dropped during the ADR 0017 refactor that moved pod mutations onto the signal-driven state machine — `mutation.status` is the contract and `jido.agent.child.*` signals already drive the slice updates that reconcile rides on top of.

## Decision needed

Pick one:

**Option A — Restore the signals.** Wrap `Mutable.mutate_and_wait/3` so `reconcile/2` casts:

```elixir
def reconcile(server, opts \\ []) when is_list(opts) do
  with {:ok, eager_unrunning} <- eager_unrunning_nodes(server) do
    cast_reconcile_signal(server, "started", %{requested: eager_unrunning})

    case Mutable.mutate_and_wait(server, ..., opts) do
      {:ok, report} ->
        cast_reconcile_signal(server, "completed", %{requested: ..., started: ..., failed: ...})
        {:ok, reconcile_report(report, eager_unrunning)}

      {:error, _} = err ->
        cast_reconcile_signal(server, "failed", %{requested: ..., error: ...})
        err
    end
  end
end
```

Per ADR 0004 dispatch is best-effort and never aborts the operation. Source is `/pod/<state.id>`.

**Option B — Supersede ADR 0004.** Update the ADR's `Status:` to `Superseded by ADR 0017`. Add a "Subsumed by mutation state machine" paragraph: reconcile is now `mutate_and_wait(ensure_node ops)`, the mutation slice exposes terminal status (`mutation.status :: :running | :completed | :failed`), and `jido.agent.child.started/.exit` already give plugins/bus subscribers everything they need. The reconcile-level envelope is redundant.

## Recommendation

Option B unless somebody can point at a concrete subscriber that pattern-matches `jido.pod.reconcile.**` and would break. The mutation state machine is already the canonical observability surface; extra envelopes around it are noise.

## Acceptance criteria

- Either: `lib/jido/pod/runtime.ex:reconcile/2` casts all three signals per ADR 0004 §Decision **and** a test asserts the signal sequence on success and failure paths.
- Or: `guides/adr/0004-pod-lifecycle-signals.md` `Status:` becomes `Superseded by ADR 0017`, with a paragraph explaining what replaced it and why.
- `mix test` and `mix q` stay green.
