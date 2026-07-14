# Ash-backed slice DSL — security engineer documentation

Ash-backed slices execute reducer actions through Ash, so authorization policies
remain the boundary for state transitions. Runtime actor, context, and tenant
data from Jido signals must reach the generated Ash reducer call.

## Stories

| ID | Story | File |
| --- | --- | --- |
| US-AJSL-18 | Authorize reducers with runtime identity | [US-AJSL-18](./US-AJSL-18-authorize-reducers-with-runtime-identity.md) |
| US-AJSL-19 | Preserve reducer policy denial errors | [US-AJSL-19](./US-AJSL-19-preserve-reducer-policy-denial-errors.md) |

## See also

- [Ash-native Jido slices RFC](../../../../../../documentation/rfc/ash-native-jido-slices.md)
- [Ash-native Jido slices plan](../../../../../../documentation/plans/ash-native-jido-slices.md)
