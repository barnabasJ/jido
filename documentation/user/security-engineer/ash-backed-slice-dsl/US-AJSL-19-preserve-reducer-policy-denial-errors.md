# US-AJSL-19 — Preserve reducer policy denial errors

**User-type:** security-engineer **Status:** spec

```gherkin
Given an Ash-backed slice reducer protected by Ash policies
When Ash forbids the generated reducer action
Then the generated Jido action returns the structured Ash denial error without a replacement slice
```

## Acceptance Criteria

- Generated reducers return `{:error, error}` for Ash policy denials.
- The error remains an Ash forbidden error instead of a string or atom.
- The failure path does not return mutated slice state.

## Tasks

- [Task 09 — Add actor/scope/context policy threading](../../../../../../docs/tasks/ash-native-jido-slices/09-add-actor-scope-context-policy-threading.md)

## See Also

- [README](./README.md)
