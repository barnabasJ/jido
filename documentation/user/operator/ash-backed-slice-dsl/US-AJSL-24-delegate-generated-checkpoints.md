# US-AJSL-24 — Delegate generated checkpoints to a custom transform

**User-type:** operator **Status:** spec

```gherkin
Given an Ash-backed slice whose durable values require application-specific encoding
When its generated slice externalizes or reinstates a checkpoint
Then the generated callbacks delegate to the transform declared by the resource
```

## Acceptance Criteria

- `jido_slice` accepts a module implementing `Jido.Persist.Transform`.
- Generated slice callbacks delegate both `externalize/1` and `reinstate/1` to that module.
- Slices without a custom transform retain attribute-metadata persistence behavior.
- The configured transform is inspectable through `Jido.Ash.Slice.Info`.

## Tasks

- [Task 16 — Migrate EventSlice reducers and checkpoint behavior](../../../../../../docs/tasks/ash-native-jido-slices/16-migrate-event-slice-reducers-and-checkpoint-behavior.md)

## See Also

- [README](./README.md)
