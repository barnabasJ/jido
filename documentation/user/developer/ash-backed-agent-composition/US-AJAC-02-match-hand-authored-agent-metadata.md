# US-AJAC-02 — Match hand-authored agent metadata

**User-type:** developer **Status:** spec

```gherkin
Given a domain-backed composition and a simple hand-authored `Jido.Agent` with the same slice mounts
When a developer compares their composition metadata
Then the domain-backed metadata matches the existing agent metadata shape
```

## Acceptance Criteria

- Domain-backed identity metadata matches a comparable `Jido.Agent` module.
- Domain-backed slice instances match the comparable `Jido.Agent` mounts.
- Domain-backed routes match the comparable `Jido.Agent` routes.
- Existing hand-authored `Jido.Agent` modules continue to compile and expose metadata.

## Tasks

- [Task 11 — Add domain-backed agent composition DSL](../../../../../../docs/tasks/ash-native-jido-slices/11-add-domain-backed-agent-composition-dsl.md)

## See Also

- [README](./README.md)
