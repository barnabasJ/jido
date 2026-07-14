# US-AJSL-23 — Deny a mounted proving reducer

**User-type:** developer **Status:** spec

```gherkin
Given a tiny Ash-backed slice reducer protected by Ash policies
When the mounted generated reducer is run by a forbidden actor
Then the agent command returns a structured error and the original slice state is unchanged
```

## Acceptance Criteria

- The proving reducer runs under Ash authorization when mounted in an agent.
- A policy denial returns a structured error through the agent command boundary.
- The denied command does not mutate the agent's mounted slice state.

## Tasks

- [Task 12 — Build a tiny proving slice and tests](../../../../../../docs/tasks/ash-native-jido-slices/12-build-a-tiny-proving-slice-and-tests.md)

## See Also

- [README](./README.md)
