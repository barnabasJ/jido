# US-AJSL-18 — Authorize reducers with runtime identity

**User-type:** security-engineer **Status:** spec

```gherkin
Given an Ash-backed slice reducer protected by Ash policies
When the generated Jido action runs with actor, context, and tenant runtime data
Then Ash receives that data and can authorize the reducer state transition
```

## Acceptance Criteria

- Generated reducers pass runtime `actor` into Ash action execution.
- Generated reducers pass runtime `context` into Ash action execution.
- Generated reducers pass runtime `tenant` or `scope` data into Ash action execution.
- Authorization is not disabled by default in generated reducer code.

## Tasks

- [Task 09 — Add actor/scope/context policy threading](../../../../../../docs/tasks/ash-native-jido-slices/09-add-actor-scope-context-policy-threading.md)

## See Also

- [README](./README.md)
