# US-AJSL-08 — Reject unsupported slice state attributes

**User-type:** developer **Status:** spec

```gherkin
Given an Ash-backed slice resource with an attribute type the Jido schema mapper does not support
When a developer asks for the derived state schema
Then the framework raises a clear error naming the unsupported Ash type
And it does not silently fall back to an unvalidated `:any` schema
```

## Acceptance criteria

- Unsupported state attribute types fail with a clear error.
- The error includes the Ash type that could not be mapped.
- The mapper does not silently degrade to `Zoi.any()` for unsupported concrete types.

## Notes

- **Reference / related code:** `Jido.Ash.Slice.Info.state_schema/1`.
- **Size:** One negative behavior test.

## Tasks

- [Task 04 — Derive slice state schema from Ash attributes](../../../../../../docs/tasks/ash-native-jido-slices/04-derive-slice-state-schema-from-ash-attributes.md)

## See also

- [README](./README.md)
