# US-AJSL-10 — Reject signals bound to missing actions

**User-type:** developer **Status:** spec

```gherkin
Given an Ash-backed slice resource with a signal bound to an action that does not exist
When the resource compiles
Then the DSL verifier fails with a clear error naming the signal and action
```

## Acceptance criteria

- Signal declarations are validated against the resource's Ash actions.
- Missing action references fail at compile time.
- The error message names the signal type and missing action.

## Notes

- **Reference / related code:** `Jido.Ash.Slice.Verifiers.SignalActionsExist`.
- **Size:** One verifier plus negative behavior test.

## Tasks

- [Task 05 — Derive signal payload schemas from Ash action inputs](../../../../../../docs/tasks/ash-native-jido-slices/05-derive-signal-payload-schemas-from-ash-action-inputs.md)

## See also

- [README](./README.md)
