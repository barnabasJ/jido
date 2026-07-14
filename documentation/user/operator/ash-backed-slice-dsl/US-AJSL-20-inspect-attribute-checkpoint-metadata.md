# US-AJSL-20 — Inspect attribute checkpoint metadata

**User-type:** operator **Status:** spec

```gherkin
Given an Ash-backed slice resource with checkpoint metadata on attributes
When an operator inspects the generated slice metadata
Then each attribute reports whether it is durable, transient, or restored
```

## Acceptance Criteria

- Attributes default to durable checkpoint behavior.
- Attributes can be marked transient for runtime-only state.
- Attributes can be marked restored for thaw-time default restoration.
- Persistence metadata is available through `Jido.Ash.Slice.Info`.

## Tasks

- [Task 10 — Add persistence metadata for attribute externalize/reinstate](../../../../../../docs/tasks/ash-native-jido-slices/10-add-persistence-metadata-for-attribute-externalize-reinstate.md)

## See Also

- [README](./README.md)
