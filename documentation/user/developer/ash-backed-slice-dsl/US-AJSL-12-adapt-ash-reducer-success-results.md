# US-AJSL-12 — Adapt Ash reducer success results

**User-type:** developer **Status:** spec

```gherkin
Given a generated Jido action for an Ash-backed slice reducer
When the Ash action returns a next slice state and directive descriptors
Then the generated action returns `{:ok, next_slice, directives}` without executing directives
```

## Acceptance criteria

- Generated actions call the real Ash generic action with the signal payload.
- The current slice is available to the Ash action through Ash action context.
- Directive descriptors are preserved in the returned list.

## Tasks

- [Task 06 — Generate reducer-compatible Jido.Action modules](../../../../../../docs/tasks/ash-native-jido-slices/06-generate-reducer-compatible-jido-action-modules.md)

## See also

- [README](./README.md)
