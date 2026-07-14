# US-AJSL-09 — Derive signal payload schemas from Ash actions

**User-type:** developer **Status:** spec

```gherkin
Given an Ash-backed slice resource with signal bindings to Ash actions
When a developer inspects signal payload metadata and schemas
Then public action arguments and accepted attributes appear as payload fields
And required, nullable, and default behavior is preserved in the derived schema
```

## Acceptance criteria

- `Jido.Ash.Slice.Info.signal_payloads/1` returns payload metadata in signal declaration order.
- Generic action arguments appear as argument-sourced payload fields.
- Accepted update/create attributes appear as attribute-sourced payload fields.
- `Jido.Ash.Slice.Info.signal_payload_schema/2` returns a Zoi object schema.

## Notes

- **Reference / related code:** `Jido.Ash.Slice.Info`, `Jido.Ash.Slice.SignalPayload`, and `Jido.Ash.Slice.PayloadField`.
- **Size:** Payload metadata structs plus Info accessors.

## Tasks

- [Task 05 — Derive signal payload schemas from Ash action inputs](../../../../../../docs/tasks/ash-native-jido-slices/05-derive-signal-payload-schemas-from-ash-action-inputs.md)

## See also

- [README](./README.md)
