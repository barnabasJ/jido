# US-AJSL-16 — Mount Ash-backed slice resources

**User-type:** developer **Status:** spec

```gherkin
Given a Jido agent with a `slices do` block
When a developer mounts an Ash-backed slice resource at an agent-owned path
Then the agent resolves it to the generated Jido slice module and seeds state at that path
```

## Acceptance criteria

- `slice :path, ExistingSlice` continues to mount existing hand-authored slices.
- `slice :path, AshSliceResource` resolves to `AshSliceResource.Jido.Slice`.
- The agent-owned mount path controls where generated slice state is seeded.

## Tasks

- [Task 08 — Teach Jido.Agent to mount Ash-backed slices](../../../../../../docs/tasks/ash-native-jido-slices/08-teach-jido-agent-to-mount-ash-backed-slices.md)

## See also

- [README](./README.md)
