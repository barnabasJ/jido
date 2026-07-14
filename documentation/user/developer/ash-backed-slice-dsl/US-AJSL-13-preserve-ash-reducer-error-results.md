# US-AJSL-13 — Preserve Ash reducer error results

**User-type:** developer **Status:** spec

```gherkin
Given a generated Jido action for an Ash-backed slice reducer
When the Ash action reports a reducer error
Then the generated action returns `{:error, reason}` and does not produce a next slice state
```

## Acceptance criteria

- Error-shaped reducer results are not converted into successful state updates.
- Generated actions return `{:error, reason}` for Ash action errors.
- Runtime directive execution is not attempted on the error path.

## Tasks

- [Task 06 — Generate reducer-compatible Jido.Action modules](../../../../../../docs/tasks/ash-native-jido-slices/06-generate-reducer-compatible-jido-action-modules.md)

## See also

- [README](./README.md)
