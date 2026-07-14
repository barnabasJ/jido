# US-AJAC-01 — Declare domain-backed agent composition

**User-type:** developer **Status:** spec

```gherkin
Given an Ash domain using the Jido domain extension
When a developer declares `jido_agent` metadata and mounts an Ash-backed slice at an explicit path
Then the domain exposes agent identity, mount instances, routes, and action ownership metadata
```

## Acceptance Criteria

- An Ash domain can declare Jido agent identity metadata.
- The domain DSL can mount an Ash-backed slice resource at an explicit path.
- The explicit path belongs to the domain composition, not the slice resource.
- Route and action ownership metadata is inspectable through `Jido.Ash.Domain.Info`.

## Tasks

- [Task 11 — Add domain-backed agent composition DSL](../../../../../../docs/tasks/ash-native-jido-slices/11-add-domain-backed-agent-composition-dsl.md)

## See Also

- [README](./README.md)
