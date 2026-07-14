# US-AJSL-11 — Generate stable reducer action modules

**User-type:** developer **Status:** spec

```gherkin
Given an Ash-backed slice resource with signal-bound generic actions
When the resource compiles
Then deterministic `Jido.Action` module names are generated and exposed through Info
```

## Acceptance criteria

- `Jido.Ash.Slice.Info.generated_action_modules/1` returns generated modules in declaration order.
- `Jido.Ash.Slice.Info.generated_action_module/2` returns the module for a named Ash action.
- Generated modules implement `Jido.Action` and expose stable action metadata.

## Tasks

- [Task 06 — Generate reducer-compatible Jido.Action modules](../../../../../../docs/tasks/ash-native-jido-slices/06-generate-reducer-compatible-jido-action-modules.md)

## See also

- [README](./README.md)
