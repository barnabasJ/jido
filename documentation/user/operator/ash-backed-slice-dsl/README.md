# Ash-backed slice DSL — operator documentation

Operators need to know which generated slice fields are checkpointed and which
runtime fields are rebuilt on thaw. Ash-backed slice metadata makes that
checkpoint behavior inspectable through package APIs and enforced by generated
transform callbacks.

## Stories

| ID | Story | File |
| --- | --- | --- |
| US-AJSL-20 | Inspect attribute checkpoint metadata | [US-AJSL-20](./US-AJSL-20-inspect-attribute-checkpoint-metadata.md) |
| US-AJSL-21 | Checkpoint only durable generated state | [US-AJSL-21](./US-AJSL-21-checkpoint-only-durable-generated-state.md) |

## See Also

- [Ash-native Jido slices RFC](../../../../../../documentation/rfc/ash-native-jido-slices.md)
- [Ash-native Jido slices plan](../../../../../../documentation/plans/ash-native-jido-slices.md)
