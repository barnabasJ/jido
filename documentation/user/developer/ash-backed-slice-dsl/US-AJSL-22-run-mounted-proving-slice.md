# US-AJSL-22 — Run a mounted proving slice

**User-type:** developer **Status:** spec

```gherkin
Given a tiny Ash-backed slice resource mounted in a Jido agent
When the agent runs the generated reducer with the original input signal
Then the generated reducer updates the mounted slice state and returns directives without executing them inline
```

## Acceptance Criteria

- The Ash-backed proving slice compiles and exposes generated slice/action metadata.
- The proving slice mounts at an agent-owned path.
- The mounted reducer receives signal payload data and updates only its slice state.
- Returned directives are surfaced to the caller instead of being executed inline.

## Tasks

- [Task 12 — Build a tiny proving slice and tests](../../../../../../docs/tasks/ash-native-jido-slices/12-build-a-tiny-proving-slice-and-tests.md)

## See Also

- [README](./README.md)
