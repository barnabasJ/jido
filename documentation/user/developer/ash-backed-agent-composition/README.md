# Ash-backed agent composition — developer documentation

Developers can declare a Jido agent composition on an Ash domain. The domain owns
agent identity and explicit slice mount paths, while reusable Ash-backed slice
resources continue to own state schemas, routes, and reducer actions.

## Stories

| ID | Story | File |
| --- | --- | --- |
| US-AJAC-01 | Declare domain-backed agent composition | [US-AJAC-01](./US-AJAC-01-declare-domain-backed-agent-composition.md) |
| US-AJAC-02 | Match hand-authored agent metadata | [US-AJAC-02](./US-AJAC-02-match-hand-authored-agent-metadata.md) |

## See Also

- [Ash-native Jido slices RFC](../../../../../../documentation/rfc/ash-native-jido-slices.md)
- [Ash-native Jido slices plan](../../../../../../documentation/plans/ash-native-jido-slices.md)
