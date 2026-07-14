# US-AJSL-21 — Checkpoint only durable generated state

**User-type:** operator **Status:** spec

```gherkin
Given an Ash-backed slice module generated from attribute checkpoint metadata
When the existing persister calls its externalize and reinstate callbacks
Then durable attributes survive, transient attributes are omitted, and restored attributes reset on thaw
```

## Acceptance Criteria

- Generated slice modules implement `Jido.Persist.Transform` callbacks.
- `externalize/1` keeps durable attributes and excludes transient/restored runtime state.
- `reinstate/1` restores durable checkpoint values and resets restored attributes from defaults.

## Tasks

- [Task 10 — Add persistence metadata for attribute externalize/reinstate](../../../../../../docs/tasks/ash-native-jido-slices/10-add-persistence-metadata-for-attribute-externalize-reinstate.md)

## See Also

- [README](./README.md)
