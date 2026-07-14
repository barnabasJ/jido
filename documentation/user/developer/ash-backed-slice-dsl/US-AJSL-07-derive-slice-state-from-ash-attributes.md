# US-AJSL-07 — Derive slice state from Ash attributes

**User-type:** developer **Status:** spec

```gherkin
Given an Ash-backed slice resource with typed Ash attributes
When a developer inspects the slice state fields and derived state schema
Then the attributes are represented as slice state fields
And static defaults, descriptions, and public metadata are available for later generation
```

## Acceptance criteria

- `Jido.Ash.Slice.Info.state_fields/1` returns attributes in declaration order.
- `Jido.Ash.Slice.Info.state_schema/1` returns a Zoi object schema.
- Static Ash defaults are applied by the derived schema.
- Required and nullable fields preserve Ash `allow_nil?` semantics.

## Notes

- **Reference / related code:** `Jido.Ash.Slice.Info` and `Jido.Ash.Slice.StateField`.
- **Size:** One state metadata struct plus Info accessors.

## Tasks

- [Task 04 — Derive slice state schema from Ash attributes](../../../../../../docs/tasks/ash-native-jido-slices/04-derive-slice-state-schema-from-ash-attributes.md)

## See also

- [README](./README.md)
