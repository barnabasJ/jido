# US-AJSL-05 — Inspect Ash-backed slice declarations

**User-type:** developer **Status:** spec

```gherkin
Given an Ash-backed slice resource with metadata and signal bindings
When a developer calls `Jido.Ash.Slice.Info`
Then they receive the declared metadata and signal bindings in a stable shape
And generated-module metadata is available as later generation tasks populate it
```

## Acceptance criteria

- `Info.name/1`, `Info.description/1`, and `Info.tags/1` return resource DSL
  values.
- `Info.signals/1` returns the declared signal type/action pairs.
- `Info.generated_slice_module/1` and `Info.generated_action_modules/1` exist as
  stable accessors for generation metadata.

## Notes

- **Reference / related code:** `Jido.Ash.Slice.Info`.
- **Size:** One Info module plus tests.

## Tasks

- [Task 03 — Add Ash-backed slice DSL structs and Info](../../../../../../docs/tasks/ash-native-jido-slices/03-add-ash-backed-slice-dsl-info.md)
- [Task 06 — Generate reducer-compatible Jido.Action modules](../../../../../../docs/tasks/ash-native-jido-slices/06-generate-reducer-compatible-jido-action-modules.md)

## See also

- [README](./README.md)
